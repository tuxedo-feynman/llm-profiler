# Local LLM Profiler: Implementation Idea Brief

## Goal

Build a simple local profiling tool for running and comparing GGUF / llama.cpp models on niche consumer hardware, especially an older MacBook with limited RAM.

The profiler should answer one practical question:

> Which local model, quantization, context size, and runtime configuration gives acceptable interactive latency without causing memory pressure or swap?

This is not meant to be a full production observability platform. It should start as a small, reliable local tool that can later grow into agent-level tracing. However be extremely cautious to assume or use dependencies. You can assume it's running on MacOS with a C compiler, and python3. 

## Current user context

The user is experimenting with local LLMs using `llama.cpp`, likely through `llama-cli` and eventually `llama-server`.

Known context:

- Hardware is niche / constrained: an older MacBook, possibly Intel, around 8 GB RAM.
- User is inspecting processes like `llama-cli` with tools such as `htop`, `ps aux`, and macOS Activity Monitor.
- User is trying GGUF models from Hugging Face, including Qwen-family models.
- User wants to build a local-first agent accessible via Telegram.
- The initial goal is local model viability, not datacenter-scale inference benchmarking.
- User wants simple tools and clear outputs, preferably scripts and CSV/JSON files that are easy to inspect.

## Why build this instead of adopting a big tool first?

There are open-source LLM observability and benchmarking tools, including GenAI-Perf, GuideLLM, Langfuse, and OpenTelemetry-based tracing. These may become useful later.

But the immediate need is narrower:

- Measure `llama.cpp` on a specific Mac.
- Compare local model configurations.
- Capture CPU, memory, and swap behavior during inference.
- Determine whether performance issues are caused by model size, context length, thread settings, or memory pressure.

A small purpose-built profiler is the right first step.

## Core concepts

The profiler should collect two categories of data at the same time.

### 1. LLM runtime metrics

These come from the model run itself.

Important metrics:

- model path
- model file size
- quantization, if inferable from filename
- prompt name
- prompt size in characters
- requested output tokens
- context size
- thread count
- batch size, if used
- Metal / GPU offload setting, if used
- total runtime
- load time, if available from llama.cpp output
- prompt eval time, if available
- prompt eval tokens/sec, if available
- eval / decode time, if available
- eval / decode tokens/sec, if available
- time to first token, if measurable

For early versions, it is acceptable to parse llama.cpp timing output from stdout/stderr rather than instrumenting the runtime directly.

### 2. System metrics

These come from macOS while the model process is running.

Important per-process metrics:

- timestamp
- PID
- command name
- CPU percent
- RSS memory in MB
- virtual memory / VSZ in MB
- thread count

Important system-wide metrics:

- free memory
- active memory
- inactive memory
- wired memory
- compressed memory
- swapins
- swapouts

The most important memory pressure signal is not whether swap exists. It is whether `swapouts` increase while inference is running.

## Key macOS commands

### Process metrics

Use `ps` to inspect the running llama process:

```bash
ps -p "$PID" -o pid,comm,%cpu,rss,vsz,nlwp
```

Notes:

- `rss` is resident memory in KB. This is the most useful process memory metric.
- `vsz` is virtual address space in KB. This can be misleadingly large.
- `%cpu` can exceed 100% on macOS because it is reported per core.
- `nlwp` is thread count.

### System memory and swap

Use:

```bash
vm_stat
```

Also capture page size:

```bash
pagesize
```

Convert pages to MB:

```text
MB = pages * page_size / 1024 / 1024
```

Important `vm_stat` fields:

- `Pages free`
- `Pages active`
- `Pages inactive`
- `Pages wired down`
- `Pages occupied by compressor`
- `Swapins`
- `Swapouts`

### Runtime resource summary

Use macOS `time` for maximum resident set size:

```bash
/usr/bin/time -l ./llama-cli ...
```

This is useful for peak memory after a run completes.

## Recommended v0 architecture

Create a small command-line project with these scripts:

```text
local-llm-profiler/
  README.md
  profile_llama.sh
  sample_system.sh
  parse_llama_timings.py
  prompts/
    short.txt
    medium.txt
    long_context.txt
  runs/
    .gitkeep
```

### `sample_system.sh`

Responsibility:

- Given a PID, sample process and system metrics every N seconds.
- Write metrics to CSV.
- Stop when the process exits.

Inputs:

```bash
./sample_system.sh <PID> <output_csv> [interval_seconds]
```

Output CSV columns:

```text
ts,pid,cpu_percent,rss_mb,vsz_mb,threads,free_mb,active_mb,inactive_mb,wired_mb,compressed_mb,swapins,swapouts
```

### `profile_llama.sh`

Responsibility:

- Run `llama-cli` with a given model and prompt.
- Start `sample_system.sh` in the background while inference runs.
- Save stdout, stderr, run metadata, and system metrics into a run directory.
- Optionally call `parse_llama_timings.py` after the run.

Example usage:

```bash
./profile_llama.sh \
  --model models/qwen.gguf \
  --prompt prompts/short.txt \
  --out runs/qwen-q4-short \
  --n-predict 256 \
  --ctx-size 4096 \
  --threads 4
```

Expected output directory:

```text
runs/qwen-q4-short/
  run.json
  stdout.txt
  stderr.txt
  system_metrics.csv
  summary.json
```

### `parse_llama_timings.py`

Responsibility:

- Parse llama.cpp timing output from `stdout.txt` and/or `stderr.txt`.
- Extract load time, prompt eval time, eval time, tokens/sec, etc.
- Read `system_metrics.csv`.
- Compute peak RSS, average CPU, max CPU, swap delta, compressed memory delta.
- Write `summary.json`.

This can be minimal at first. If timing patterns vary across llama.cpp versions, preserve raw logs and parse best-effort.

## Suggested `run.json` schema

```json
{
  "model_path": "models/qwen.gguf",
  "model_file_size_mb": 1024.0,
  "model_name_guess": "qwen.gguf",
  "quantization_guess": "Q4_K_M",
  "prompt_file": "prompts/short.txt",
  "prompt_chars": 128,
  "n_predict": 256,
  "ctx_size": 4096,
  "threads": 4,
  "batch_size": null,
  "llama_binary": "./llama-cli",
  "started_at": "2026-06-11T15:00:00-07:00",
  "ended_at": "2026-06-11T15:00:22-07:00",
  "exit_code": 0
}
```

## Suggested `summary.json` schema

```json
{
  "total_seconds": 22.3,
  "load_time_ms": null,
  "prompt_eval_time_ms": null,
  "prompt_eval_tokens_per_sec": null,
  "eval_time_ms": null,
  "eval_tokens_per_sec": null,
  "peak_rss_mb": 1780.2,
  "avg_cpu_percent": 245.0,
  "max_cpu_percent": 388.0,
  "start_swapouts": 123456,
  "end_swapouts": 123456,
  "swapouts_delta": 0,
  "start_compressed_mb": 600.0,
  "end_compressed_mb": 650.0,
  "compressed_mb_delta": 50.0,
  "verdict": "fits_without_swap"
}
```

## Simple verdict rules

The tool should generate a human-readable verdict for each run.

### Good run

Conditions:

- `swapouts_delta == 0`
- RSS is stable or expected
- compressed memory is not rapidly growing
- CPU utilization is high
- tokens/sec is acceptable

Verdict:

```text
fits_without_swap
```

### Memory pressure run

Conditions:

- `swapouts_delta > 0`
- compressed memory rises significantly
- tokens/sec drops or total latency is high

Verdict:

```text
memory_pressure_or_swapping
```

### CPU-limited run

Conditions:

- no swapouts
- high CPU utilization
- slow tokens/sec

Verdict:

```text
cpu_limited
```

### Underutilized run

Conditions:

- no swapouts
- low CPU utilization
- slow tokens/sec

Verdict:

```text
underutilized_runtime_config
```

Possible causes:

- too few threads
- bad batch settings
- server/client overhead
- Metal/offload misconfiguration
- waiting on I/O

## Benchmark prompts

Include a small prompt suite so runs are comparable.

### `prompts/short.txt`

```text
Explain what a transformer is in simple terms.
```

### `prompts/medium.txt`

```text
Write a concise but clear explanation of how attention works in transformers. Include the roles of queries, keys, and values. Avoid equations unless necessary.
```

### `prompts/long_context.txt`

This should contain a few thousand tokens of pasted context followed by a question. The purpose is to test prompt eval speed and context pressure.

## Important benchmark dimensions

The user will likely want to compare:

- model family
- model size
- quantization
- context size
- thread count
- batch size
- `llama-cli` vs `llama-server`
- short prompt vs long context
- cold run vs warm run

Start with `llama-cli`. Add `llama-server` support later.

## Phase 1: llama-cli profiler

Build this first.

Acceptance criteria:

- Can run one prompt against one model.
- Captures stdout and stderr.
- Captures system metrics once per second.
- Writes `run.json`, `system_metrics.csv`, and `summary.json`.
- Computes peak RSS and swapouts delta.
- Does not require external services.
- Works on macOS.

## Phase 2: repeated benchmark matrix

Add a simple runner that executes multiple combinations.

Example matrix:

```text
models:
  - qwen3-4b-q4.gguf
  - qwen3-4b-q5.gguf
prompts:
  - short.txt
  - medium.txt
  - long_context.txt
threads:
  - 2
  - 4
ctx_size:
  - 2048
  - 4096
```

Output:

```text
runs/index.csv
```

Suggested columns:

```text
run_id,model,quant,prompt,threads,ctx_size,total_seconds,eval_tokens_per_sec,peak_rss_mb,swapouts_delta,verdict
```

## Phase 3: llama-server support

Later, add support for `llama-server` so the user can test the runtime mode that will likely power a Telegram agent.

Measure:

- request latency
- time to first token
- streaming tokens/sec
- total response time
- server process RSS
- swapouts delta

This may require a small Python client using streaming HTTP responses.

## Phase 4: agent-loop tracing

Once the Telegram agent exists, add JSONL tracing around the whole agent turn.

Suggested stages:

```text
telegram_receive
session_load
memory_search
prompt_assembly
model_call
model_prefill
model_decode
tool_call
telegram_send
```

Each trace event should look like:

```json
{
  "ts": "2026-06-11T15:00:00-07:00",
  "run_id": "abc123",
  "stage": "model_call",
  "model": "Qwen3-4B-Instruct-Q4_K_M",
  "input_tokens": 850,
  "output_tokens": 128,
  "ttft_ms": 2200,
  "total_ms": 14800,
  "tokens_per_sec": 9.4,
  "rss_mb": 1800
}
```

This matters because the agent architecture will eventually include more than model inference. A local-first agent loop may include message ingestion, session loading, context assembly, memory search, model invocation, tool execution, state persistence, and response delivery.

## Human interpretation guide

The profiler should help answer these questions:

### Does the model fit?

Look at:

- peak RSS
- compressed memory delta
- swapouts delta

If swapouts increase during inference, the model/configuration is too memory-heavy for comfortable use.

### Is the model fast enough?

Look at:

- time to first token
- eval tokens/sec
- total latency

For an interactive Telegram agent on old hardware, rough targets are:

- TTFT under 3-5 seconds feels okay.
- 8-15 generated tokens/sec feels usable.
- Below 5 tokens/sec feels sluggish.
- Long prompt TTFT above 20 seconds will feel broken.

### Is the bottleneck CPU or memory?

Likely memory pressure:

- swapouts increasing
- compressed memory rising
- tokens/sec degrading

Likely CPU-bound:

- no swapouts
- high CPU
- stable memory
- slow but consistent tokens/sec

Likely underconfigured runtime:

- no swapouts
- low CPU
- slow tokens/sec

## Non-goals for v0

Do not build these initially:

- Web dashboard
- Langfuse integration
- OpenTelemetry integration
- multi-user support
- cloud benchmarking
- GPU/datacenter benchmarking
- complex statistical analysis
- automatic model downloading

Keep v0 simple and local.

## Implementation preference

Use shell scripts for process orchestration and macOS metric collection.

Use Python only where it clearly simplifies parsing and summarization.

Avoid heavyweight dependencies.

Prefer files that can be inspected manually:

- CSV for sampled metrics
- JSON for run metadata and summaries
- raw stdout/stderr logs for debugging

## First coding task

Implement:

```text
sample_system.sh
profile_llama.sh
parse_llama_timings.py
README.md
```

Then test with a single known model and a short prompt.

The first useful output is not a beautiful dashboard. It is a run directory that clearly shows:

```text
Did this model run?
How fast was it?
How much memory did it use?
Did it swap?
```
