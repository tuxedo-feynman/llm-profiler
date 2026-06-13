#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

LLAMA_BINARY=""
MODEL_PATH=""
PROMPT_FILE=""
OUT_DIR=""
N_PREDICT=256
CTX_SIZE=4096
THREADS=4
BATCH_SIZE=""
NGL=""

usage() {
    cat >&2 << 'EOF'
Usage: profile_llama.sh --llama-binary <path> --model <model.gguf> --prompt <prompt.txt> --out <run_dir> [options]

Options:
  --n-predict N     Tokens to generate (default: 256)
  --ctx-size N      Context size (default: 4096)
  --threads N       Thread count (default: 4)
  --batch-size N    Batch size (optional)
  --ngl N           GPU layers to offload (optional)
EOF
    exit 1
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --llama-binary) LLAMA_BINARY="$2"; shift 2 ;;
        --model)        MODEL_PATH="$2";   shift 2 ;;
        --prompt)       PROMPT_FILE="$2";  shift 2 ;;
        --out)          OUT_DIR="$2";      shift 2 ;;
        --n-predict)    N_PREDICT="$2";    shift 2 ;;
        --ctx-size)     CTX_SIZE="$2";     shift 2 ;;
        --threads)      THREADS="$2";      shift 2 ;;
        --batch-size)   BATCH_SIZE="$2";   shift 2 ;;
        --ngl)          NGL="$2";          shift 2 ;;
        -h|--help)      usage ;;
        *) echo "Unknown argument: $1" >&2; usage ;;
    esac
done

[ -z "$LLAMA_BINARY" ] && { echo "Error: --llama-binary required" >&2; usage; }
[ -z "$MODEL_PATH" ]   && { echo "Error: --model required" >&2; usage; }
[ -z "$PROMPT_FILE" ]  && { echo "Error: --prompt required" >&2; usage; }
[ -z "$OUT_DIR" ]      && { echo "Error: --out required" >&2; usage; }

[ ! -f "$LLAMA_BINARY" ] && { echo "Error: binary not found: $LLAMA_BINARY" >&2; exit 1; }
[ ! -f "$MODEL_PATH" ]   && { echo "Error: model not found: $MODEL_PATH" >&2; exit 1; }
[ ! -f "$PROMPT_FILE" ]  && { echo "Error: prompt not found: $PROMPT_FILE" >&2; exit 1; }

mkdir -p "$OUT_DIR"

MODEL_NAME=$(basename "$MODEL_PATH")
MODEL_SIZE_MB=$(stat -f %z "$MODEL_PATH" | awk '{printf "%.2f", $1 / 1048576}')
PROMPT_CHARS=$(wc -c < "$PROMPT_FILE" | tr -d ' ')
STARTED_AT=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

echo "[profiler] Model:  $MODEL_NAME ($MODEL_SIZE_MB MB)"
echo "[profiler] Prompt: $(basename "$PROMPT_FILE") ($PROMPT_CHARS bytes)"
echo "[profiler] Output: $OUT_DIR"

# Write initial run.json
export LLP_OUT_DIR="$OUT_DIR" \
       LLP_MODEL_PATH="$MODEL_PATH" \
       LLP_MODEL_NAME="$MODEL_NAME" \
       LLP_MODEL_SIZE_MB="$MODEL_SIZE_MB" \
       LLP_PROMPT_FILE="$PROMPT_FILE" \
       LLP_PROMPT_CHARS="$PROMPT_CHARS" \
       LLP_N_PREDICT="$N_PREDICT" \
       LLP_CTX_SIZE="$CTX_SIZE" \
       LLP_THREADS="$THREADS" \
       LLP_BATCH_SIZE="${BATCH_SIZE:-}" \
       LLP_NGL="${NGL:-}" \
       LLP_LLAMA_BINARY="$LLAMA_BINARY" \
       LLP_STARTED_AT="$STARTED_AT"

python3 << 'PYEOF'
import json, os, re

def maybe_int(v):
    v = (v or '').strip()
    return int(v) if v.lstrip('-').isdigit() else None

def guess_quant(name):
    m = re.search(r'\b((?:IQ|Q)\d+(?:_[A-Z0-9]+)*)\b', name.upper())
    return m.group(1) if m else None

data = {
    "model_path":        os.environ['LLP_MODEL_PATH'],
    "model_file_size_mb": float(os.environ['LLP_MODEL_SIZE_MB']),
    "model_name_guess":  os.environ['LLP_MODEL_NAME'],
    "quantization_guess": guess_quant(os.environ['LLP_MODEL_NAME']),
    "prompt_file":       os.environ['LLP_PROMPT_FILE'],
    "prompt_chars":      int(os.environ['LLP_PROMPT_CHARS']),
    "n_predict":         int(os.environ['LLP_N_PREDICT']),
    "ctx_size":          int(os.environ['LLP_CTX_SIZE']),
    "threads":           int(os.environ['LLP_THREADS']),
    "batch_size":        maybe_int(os.environ.get('LLP_BATCH_SIZE', '')),
    "ngl":               maybe_int(os.environ.get('LLP_NGL', '')),
    "llama_binary":      os.environ['LLP_LLAMA_BINARY'],
    "started_at":        os.environ['LLP_STARTED_AT'],
    "ended_at":          None,
    "exit_code":         None,
}
with open(os.path.join(os.environ['LLP_OUT_DIR'], 'run.json'), 'w') as f:
    json.dump(data, f, indent=2)
PYEOF

# Build the llama-cli command
LLAMA_CMD=("$LLAMA_BINARY"
    --model "$MODEL_PATH"
    --file  "$PROMPT_FILE"
    --n-predict "$N_PREDICT"
    --ctx-size  "$CTX_SIZE"
    --threads   "$THREADS"
)
[ -n "$BATCH_SIZE" ] && LLAMA_CMD+=(--batch-size "$BATCH_SIZE")
[ -n "$NGL" ]        && LLAMA_CMD+=(--ngl "$NGL")

SAMPLER_PID=""
LLAMA_PID=""

cleanup() {
    [ -n "$SAMPLER_PID" ] && kill "$SAMPLER_PID" 2>/dev/null || true
    [ -n "$LLAMA_PID" ]   && kill "$LLAMA_PID"   2>/dev/null || true
}
trap cleanup EXIT INT TERM

echo "[profiler] Starting inference..."

"${LLAMA_CMD[@]}" > "$OUT_DIR/stdout.txt" 2> "$OUT_DIR/stderr.txt" &
LLAMA_PID=$!

"$SCRIPT_DIR/sample_system.sh" "$LLAMA_PID" "$OUT_DIR/system_metrics.csv" 1 &
SAMPLER_PID=$!

set +e
wait "$LLAMA_PID"
EXIT_CODE=$?
set -e

ENDED_AT=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

kill "$SAMPLER_PID" 2>/dev/null || true
wait "$SAMPLER_PID" 2>/dev/null || true
SAMPLER_PID=""

# Finalize run.json
export LLP_ENDED_AT="$ENDED_AT" LLP_EXIT_CODE="$EXIT_CODE"
python3 << 'PYEOF'
import json, os

path = os.path.join(os.environ['LLP_OUT_DIR'], 'run.json')
with open(path) as f:
    data = json.load(f)
data['ended_at']  = os.environ['LLP_ENDED_AT']
data['exit_code'] = int(os.environ['LLP_EXIT_CODE'])
with open(path, 'w') as f:
    json.dump(data, f, indent=2)
PYEOF

if [ "$EXIT_CODE" -ne 0 ]; then
    echo "[profiler] Warning: llama-cli exited with code $EXIT_CODE — check $OUT_DIR/stderr.txt" >&2
fi

echo "[profiler] Parsing timings..."
python3 "$SCRIPT_DIR/parse_llama_timings.py" "$OUT_DIR" || {
    echo "[profiler] Warning: parse failed — raw logs are in $OUT_DIR/" >&2
}
