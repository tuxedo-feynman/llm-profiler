# local-llm-profiler

Profiles `llama-cli` runs on macOS. Captures system metrics while inference runs and produces a verdict on whether the model fits comfortably in memory.

## Requirements

- macOS (uses `vm_stat`, `pagesize`, `ps -M`, `stat -f`)
- `llama-cli` built from source
- `python3` (stdlib only)

## Usage

```bash
./profile_llama.sh \
  --llama-binary ~/llama.cpp/build/bin/llama-cli \
  --out runs/qwen3-4b-q4-short \
  --prompt prompts/short.txt \
  -- -m models/qwen3-4b-q4_k_m.gguf -n 256 -c 4096 -t 4
```

Everything after `--` is passed directly to llama-cli unchanged. `--prompt` is optional — it records the prompt file in metadata and injects `--file` into the llama-cli call. Without it, pass `-f` or `-p` yourself in the llama-cli args.

```bash
# HuggingFace model
./profile_llama.sh --llama-binary ./llama-cli --out runs/hf-test \
  --prompt prompts/short.txt \
  -- -hf Qwen/Qwen3-4B-GGUF -n 256 -c 4096 -t 4

# With mlock and flash attention
./profile_llama.sh --llama-binary ./llama-cli --out runs/mlock-test \
  --prompt prompts/short.txt \
  -- -m models/qwen.gguf --mlock -fa -n 256 -c 4096 -t 4
```

Make scripts executable first:

```bash
chmod +x profile_llama.sh sample_system.sh
```

## Output

Each run produces a directory:

```
runs/qwen3-4b-q4-short/
  run.json            # run config + start/end times
  stdout.txt          # llama-cli stdout (generated text)
  stderr.txt          # llama-cli stderr (timing lines live here)
  system_metrics.csv  # per-second: CPU, RSS, swap, compressed memory
  summary.json        # parsed timings + peak metrics + verdict
```

### Key fields in summary.json

| Field | Meaning |
|---|---|
| `eval_tokens_per_sec` | Generation speed |
| `peak_rss_mb` | Peak resident memory |
| `swapouts_delta` | Swap pages written during the run (0 = good) |
| `peak_swapout_rate_per_min` | Worst burst of swapping observed |
| `compressed_mb_delta` | Change in compressed memory |
| `avg_cpu_percent` / `max_cpu_percent` | CPU utilization (can exceed 100% per core) |
| `verdict` | `fits_without_swap` or `memory_pressure_or_swapping` |

### Reading the CSV

`system_metrics.csv` has one row per second. `swapins` and `swapouts` are cumulative totals from `vm_stat` — subtract any two rows to get the delta over that window.

## Prompts

| File | Purpose |
|---|---|
| `prompts/short.txt` | Quick sanity check, fast run |
| `prompts/medium.txt` | Tests generation quality and speed |
| `prompts/long_context.txt` | Fill in yourself — tests prompt eval and context pressure |

## Interpreting results

**Does the model fit?**
`swapouts_delta == 0` means the model ran without pushing pages to swap. Any positive value means memory pressure.

**Is it fast enough?**
For an interactive agent on older hardware: 8–15 tok/s feels usable, below 5 tok/s feels sluggish, TTFT above 20s will feel broken.

**CPU vs memory bottleneck?**
High CPU + stable RSS + no swaps = CPU-bound (expected). High RSS + rising compressed memory + swapouts = memory-bound.

## Running sample_system.sh standalone

```bash
./sample_system.sh <PID> output.csv [interval_seconds]
```

Samples until the process exits. Default interval is 1 second.

## Parsing timings standalone

```bash
python3 parse_llama_timings.py runs/my-run/
```

Reads `stdout.txt`, `stderr.txt`, and `system_metrics.csv` from the run directory; writes `summary.json`.
