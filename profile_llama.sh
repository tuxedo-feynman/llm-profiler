#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

LLAMA_BINARY=""
OUT_DIR=""
PROMPT_FILE=""
LLAMA_ARGS=()

usage() {
    cat >&2 << 'EOF'
Usage: profile_llama.sh --llama-binary <path> --out <run_dir> [--prompt <file>] -- [llama-cli args...]

  --llama-binary    path to llama-cli binary (required)
  --out             output directory for this run (required)
  --prompt          prompt file; records metadata and injects --file into llama-cli (optional)

Everything after -- is passed directly to llama-cli unchanged.

Examples:
  ./profile_llama.sh --llama-binary ./llama-cli --out runs/q4-short \
    --prompt prompts/short.txt \
    -- -m models/qwen.gguf -n 256 -c 4096 -t 4

  ./profile_llama.sh --llama-binary ./llama-cli --out runs/hf-short \
    --prompt prompts/short.txt \
    -- -hf Qwen/Qwen3-4B-GGUF -n 256 -c 4096 -t 4
EOF
    exit 1
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --llama-binary) LLAMA_BINARY="$2"; shift 2 ;;
        --out)          OUT_DIR="$2";       shift 2 ;;
        --prompt)       PROMPT_FILE="$2";   shift 2 ;;
        -h|--help)      usage ;;
        --)             shift; LLAMA_ARGS=("$@"); break ;;
        *) echo "Unknown argument: $1" >&2; usage ;;
    esac
done

[ -z "$LLAMA_BINARY" ] && { echo "Error: --llama-binary required" >&2; usage; }
[ -z "$OUT_DIR" ]      && { echo "Error: --out required" >&2; usage; }
[ ! -f "$LLAMA_BINARY" ] && { echo "Error: binary not found: $LLAMA_BINARY" >&2; exit 1; }
[ -n "$PROMPT_FILE" ] && [ ! -f "$PROMPT_FILE" ] && { echo "Error: prompt not found: $PROMPT_FILE" >&2; exit 1; }

mkdir -p "$OUT_DIR"

STARTED_AT=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
PROMPT_CHARS=""
[ -n "$PROMPT_FILE" ] && PROMPT_CHARS=$(wc -c < "$PROMPT_FILE" | tr -d ' ')

# Encode LLAMA_ARGS as JSON so Python receives them correctly regardless of spaces in paths
if [ ${#LLAMA_ARGS[@]} -gt 0 ]; then
    LLP_LLAMA_ARGS_JSON=$(python3 -c "import json,sys; print(json.dumps(sys.argv[1:]))" "${LLAMA_ARGS[@]}")
else
    LLP_LLAMA_ARGS_JSON='[]'
fi

echo "[profiler] Binary:  $LLAMA_BINARY"
[ -n "$PROMPT_FILE" ] && echo "[profiler] Prompt:  $PROMPT_FILE ($PROMPT_CHARS bytes)"
echo "[profiler] Output:  $OUT_DIR"
echo "[profiler] Args:    ${LLAMA_ARGS[*]:-<none>}"

export LLP_OUT_DIR="$OUT_DIR" \
       LLP_LLAMA_BINARY="$LLAMA_BINARY" \
       LLP_PROMPT_FILE="${PROMPT_FILE:-}" \
       LLP_PROMPT_CHARS="${PROMPT_CHARS:-}" \
       LLP_STARTED_AT="$STARTED_AT" \
       LLP_LLAMA_ARGS_JSON="$LLP_LLAMA_ARGS_JSON"

python3 << 'PYEOF'
import json, os, re

args = json.loads(os.environ['LLP_LLAMA_ARGS_JSON'])

KNOWN_VALUED = {
    '-m': 'model_path',      '--model': 'model_path',
    '-hf': 'hf_repo',
    '--model-url': 'model_url',
    '-n': 'n_predict',       '--n-predict': 'n_predict',
    '-c': 'ctx_size',        '--ctx-size': 'ctx_size',
    '-t': 'threads',         '--threads': 'threads',
    '-b': 'batch_size',      '--batch-size': 'batch_size',
    '-ngl': 'ngl',           '--n-gpu-layers': 'ngl',
    '-f': 'prompt_file_arg', '--file': 'prompt_file_arg',
    '-p': 'prompt_text',     '--prompt': 'prompt_text',
}

known = {}
extra = []
i = 0
while i < len(args):
    arg = args[i]
    if arg in KNOWN_VALUED and i + 1 < len(args):
        known[KNOWN_VALUED[arg]] = args[i + 1]
        i += 2
    else:
        extra.append(arg)
        i += 1

def to_int(v):
    try: return int(v)
    except (TypeError, ValueError): return None

def guess_quant(name):
    m = re.search(r'\b((?:IQ|Q)\d+(?:_[A-Z0-9]+)*)\b', (name or '').upper())
    return m.group(1) if m else None

model_path = known.get('model_path')
model_size_mb = None
model_name = None
if model_path:
    model_name = os.path.basename(model_path)
    if os.path.isfile(model_path):
        model_size_mb = round(os.path.getsize(model_path) / 1048576, 2)

prompt_file = os.environ.get('LLP_PROMPT_FILE') or known.get('prompt_file_arg')
prompt_chars_str = os.environ.get('LLP_PROMPT_CHARS', '').strip()
prompt_chars = int(prompt_chars_str) if prompt_chars_str.isdigit() else None
if prompt_chars is None and prompt_file and os.path.isfile(prompt_file):
    prompt_chars = os.path.getsize(prompt_file)

data = {
    'llama_binary':       os.environ['LLP_LLAMA_BINARY'],
    'started_at':         os.environ['LLP_STARTED_AT'],
    'ended_at':           None,
    'exit_code':          None,
    'model_path':         model_path,
    'model_file_size_mb': model_size_mb,
    'model_name_guess':   model_name,
    'quantization_guess': guess_quant(model_name),
    'hf_repo':            known.get('hf_repo'),
    'model_url':          known.get('model_url'),
    'prompt_file':        prompt_file,
    'prompt_chars':       prompt_chars,
    'n_predict':          to_int(known.get('n_predict')),
    'ctx_size':           to_int(known.get('ctx_size')),
    'threads':            to_int(known.get('threads')),
    'batch_size':         to_int(known.get('batch_size')),
    'ngl':                to_int(known.get('ngl')),
    'extra_args':         extra,
}
with open(os.path.join(os.environ['LLP_OUT_DIR'], 'run.json'), 'w') as f:
    json.dump(data, f, indent=2)
PYEOF

# Build llama-cli command: binary + optional --file + all passthrough args
LLAMA_CMD=("$LLAMA_BINARY")
[ -n "$PROMPT_FILE" ] && LLAMA_CMD+=(--file "$PROMPT_FILE")
LLAMA_CMD+=("${LLAMA_ARGS[@]+"${LLAMA_ARGS[@]}"}")

SAMPLER_PID=""
LLAMA_PID=""

cleanup() {
    [ -n "$SAMPLER_PID" ] && kill "$SAMPLER_PID" 2>/dev/null || true
    [ -n "$LLAMA_PID" ]   && kill "$LLAMA_PID"   2>/dev/null || true
}
trap cleanup EXIT INT TERM

echo "[profiler] Starting inference..."

# Tee stdout and stderr live to terminal and to files
"${LLAMA_CMD[@]}" \
    > >(tee "$OUT_DIR/stdout.txt") \
    2> >(tee "$OUT_DIR/stderr.txt" >&2) &
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

# Give tee processes a moment to flush before we read the files
sleep 0.2

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
    echo "[profiler] llama-cli exited with code $EXIT_CODE" >&2
fi

echo "[profiler] Parsing timings..."
python3 "$SCRIPT_DIR/parse_llama_timings.py" "$OUT_DIR" || {
    echo "[profiler] Warning: parse failed — raw logs are in $OUT_DIR/" >&2
}
