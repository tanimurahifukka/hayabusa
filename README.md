# Hayabusa

### Swift-Native LLM Inference Server for Apple Silicon

Hayabusa is a high-performance LLM inference server built from scratch in Swift, optimized for Apple Silicon. It uses continuous batching on llama.cpp with zero Python overhead.

> **Status (2026-05):** the llama.cpp backend is the supported execution path on `main`. The MLX backend is currently disabled at startup pending a migration to the new `mlx-swift-lm` 0.2x+ API; use `--backend llama` or `--dispatcher-only`. The benchmark tables below were captured on an earlier revision where the MLX backend was operational and are kept as historical reference rather than reproducible numbers on the current commit.

## Why Hayabusa?

| Problem | Existing Solution | Limitation |
|---------|------------------|------------|
| Local LLM serving | Ollama | Serial processing, no continuous batching |
| High-throughput inference | vLLM | No Apple Silicon / Metal support |
| Apple Silicon ML | MLX | No production HTTP server |

**Hayabusa fills the gap** -- a production-ready, OpenAI-compatible inference server purpose-built for Apple Silicon.

## Performance

> The tables in this section were measured on a revision where both backends were operational and `bench_vs_ollama.py` ran the streaming path. The current server does not yet implement SSE streaming, so re-running the same script today will not reproduce the streaming TTFT numbers — see Roadmap. Numbers are presented as historical reference, not a reproducible baseline on the current commit.

### Hayabusa vs Ollama (Qwen3.5-9B, same model, same hardware)

| Metric | Hayabusa | Ollama | Improvement |
|--------|----------|--------|-------------|
| Avg Latency (conc=1) | 9,818 ms | 42,078 ms | **4.3x faster** |
| P95 Latency (conc=1) | 20,914 ms | 76,009 ms | **3.6x faster** |
| Throughput (conc=8) | 51.9 tok/s | 33.4 tok/s | **1.6x higher** |

> Mac Studio M3 Ultra 96GB, Qwen3.5-9B Q4_K_M, max_tokens=128. Captured before MLX backend was disabled on `main`.

### llama.cpp vs MLX Backend (Qwen3-8B, 512-token I/O)

| Conc | llama.cpp tok/s | MLX tok/s | llama.cpp RSS | MLX RSS | Memory Ratio |
|------|----------------|-----------|---------------|---------|-------------|
| 1 | 83.5 | 76.6 | 14,149 MB | 4,574 MB | **3.1x less** |
| 4 | 103.5 | 90.2 | 14,172 MB | 4,578 MB | **3.1x less** |
| 8 | 88.0 | 89.1 | 14,182 MB | 4,578 MB | **3.1x less** |
| 16 | 94.9 | 90.4 | 14,184 MB | 4,573 MB | **3.1x less** |

> MLX achieves comparable throughput with ~3x less memory, making it ideal for memory-constrained devices.

### Qwen3.5-9B: llama.cpp vs MLX (512-token I/O)

| Conc | llama.cpp tok/s | MLX tok/s | llama.cpp Avg (ms) | MLX Avg (ms) | llama.cpp P95 | MLX P95 |
|------|----------------|-----------|-------------------|-------------|--------------|---------|
| 1 | 67.4 | 57.0 | 79,828 | 94,556 | 144,770 | 171,315 |
| 2 | 65.9 | 63.5 | 85,571 | 89,017 | 155,418 | 161,161 |
| 4 | 71.3 | 68.9 | 86,734 | 89,428 | 143,504 | 148,588 |
| 8 | 78.5 | 68.7 | 89,664 | 102,408 | 130,490 | 149,018 |
| 16 | 76.5 | 68.5 | 112,057 | 126,696 | 133,770 | 149,399 |
| 20 | 79.5 | 68.2 | 128,017 | 148,522 | 128,832 | 150,032 |

**Memory Usage:**

| Conc | llama.cpp RSS | MLX RSS | Ratio |
|------|--------------|---------|-------|
| 1 | 9,156 MB | 5,037 MB | **1.8x less** |
| 8 | 9,194 MB | 5,049 MB | **1.8x less** |
| 20 | 9,243 MB | 5,068 MB | **1.8x less** |

> Mac Studio M3 Ultra 96GB, Qwen3.5-9B, prompt ~512 tokens, output 512 tokens, 20 requests/level.
> llama.cpp has higher throughput with continuous batching; MLX uses ~45% less memory.
> Raw data: `scripts/bench_qwen35_final.json`

## Features

- **Swift Native** -- zero Python overhead, direct Metal GPU access
- **OpenAI-Compatible API** -- non-streaming `/v1/chat/completions` (SSE streaming is on the roadmap)
- **llama.cpp backend** -- GGUF models with continuous batching (default, supported on `main`)
- **MLX backend** -- HuggingFace models; currently disabled pending mlx-swift-lm 0.2x+ migration
- **Continuous Batching** -- concurrent request processing with shared KV cache
- **Job dispatcher** -- command-room Job lease integration (`--dispatcher-only` mode for edge nodes)
- **Slot priority** -- two-level (`high` / `low`) admission via the `priority` field; a richer realtime / batch lane model is in progress

## Quick Start

### Prerequisites

- macOS 14+ (Sonnet or later)
- Apple Silicon (M1/M2/M3/M4)
- Xcode 15+ / Swift 5.10+

### Build llama.cpp

`vendor/llama.cpp` is intentionally untracked so users build it locally. Pin to a
known-good commit when cloning to keep builds reproducible:

```bash
# Pin to the upstream llama.cpp commit Hayabusa was last built and tested against.
# Update this SHA (and rebuild) whenever you intentionally move to a newer llama.cpp.
LLAMA_CPP_REF=c9872a2575acc65834deb15a1f5155f6dbc75229

git clone https://github.com/ggml-org/llama.cpp vendor/llama.cpp
cd vendor/llama.cpp
git checkout "$LLAMA_CPP_REF"
cmake -B build -DGGML_METAL=ON -DBUILD_SHARED_LIBS=OFF
cmake --build build --config Release -j$(sysctl -n hw.ncpu)
cd ../..
```

### Download a Model

```bash
# GGUF (for llama.cpp backend)
huggingface-cli download unsloth/Qwen3.5-9B-GGUF Qwen3.5-9B-Q4_K_M.gguf \
  --local-dir models/
```

### Build & Run

```bash
# Build
swift build

# Run with llama.cpp backend (supported on main)
.build/debug/Hayabusa models/Qwen3.5-9B-Q4_K_M.gguf --backend llama

# Dispatcher-only mode (no model, no HTTP server; for edge worker nodes)
HAYABUSA_CONFIG=config/hayabusa.dev.json \
  .build/debug/Hayabusa --dispatcher-only

# Custom port and slot count
HAYABUSA_PORT=8081 .build/debug/Hayabusa models/Qwen3.5-9B-Q4_K_M.gguf \
  --backend llama --slots 8 --ctx-per-slot 4096
```

> The MLX backend exists in the source tree (`--backend mlx`) but currently
> raises `modelLoadFailed` at startup because the `mlx-swift-lm` 0.2x+ loader
> API needs a migration. Do not include `--backend mlx` in scripts until that
> migration lands.

### Edge STT + Clinical Summarize (clinic voicemail pipeline)

The `stt.transcribe` and `llm.summarize_call` workers process clinic voicemail
through the command-room job queue (OpenPBX emits events / command-room decides /
Hayabusa processes — PBX never calls AI services directly).

```bash
# 1. Resident whisper-server (model stays loaded, Metal GPU).
#    Must run as a GUI-session LaunchAgent — running whisper under launchd
#    daemons (or spawning it from one) deadlocks Metal initialization.
#    Edit model path in the plist first.
cp config/com.tanimura.whisper-server.plist ~/Library/LaunchAgents/
launchctl load ~/Library/LaunchAgents/com.tanimura.whisper-server.plist
curl http://127.0.0.1:7892/health   # 200 once the model is loaded

# 2. Edge worker node (STT via resident server + clinical summarize)
HAYABUSA_CONFIG=config/hayabusa.edge.dev.json \
HAYABUSA_WORKER_TOKEN=... \
HAYABUSA_WHISPER_BIN=vendor/whisper.cpp/build/bin/whisper-cli \
HAYABUSA_WHISPER_MODEL=$HOME/models/ggml-large-v3-turbo-q5_0.bin \
HAYABUSA_WHISPER_SERVER_URL=http://127.0.0.1:7892 \
HAYABUSA_WHISPER_PROMPT_CLINICAL='以下は皮膚科診察中の医師の口述記録です。…' \
HAYABUSA_WHISPER_PROMPT_VOICEMAIL='以下は皮膚科クリニックへの留守電です。…' \
HAYABUSA_STT_TRANSCRIPTS_DIR=$HOME/hayabusa-data/transcripts \
HAYABUSA_LLM_URL=http://127.0.0.1:8080 \
  .build/release/Hayabusa --dispatcher-only
```

Notes:

- `HAYABUSA_WHISPER_SERVER_URL` enables the resident-server mode (per-request
  `prompt`, no model reload per job). On any server failure the worker falls
  back to spawning `whisper-cli` (CPU-only under launchd via
  `HAYABUSA_STT_NO_GPU`).
- whisper-server must run with `--convert` (and ffmpeg on PATH): without it,
  this vendor revision treats the uploaded multipart body as a file *name* and
  every `/inference` request fails with HTTP 400.
- `sttKind` in the job payload (`"clinical"` for the 診療 9010 box,
  `"voicemail"` otherwise) selects the initial prompt.
- `HAYABUSA_STT_TRANSCRIPTS_DIR` keeps the full transcript on the edge; only a
  `transcriptRef` (`edge://<pbxInstanceId>/<uniqueId>`) is reported to
  command-room. The `llm.summarize_call` worker resolves that ref locally and
  returns only the structured summary.
- Do NOT link whisper.cpp into Hayabusa as a SwiftPM library: the binary
  already links llama.cpp's ggml, and a second ggml copy causes symbol
  conflicts. The resident whisper-server + HTTP client is the supported path.

### Send a Request

```bash
curl http://localhost:8080/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{
    "model": "local",
    "messages": [{"role": "user", "content": "Hello!"}],
    "max_tokens": 256
  }'
```

## API

### `POST /v1/chat/completions`

OpenAI-compatible chat completion endpoint.

```json
{
  "model": "local",
  "messages": [
    {"role": "system", "content": "You are a helpful assistant."},
    {"role": "user", "content": "What is 2+2?"}
  ],
  "max_tokens": 256,
  "temperature": 0.7,
  "priority": "realtime"
}
```

### `GET /health`

Health check endpoint.

### `GET /slots`

Diagnostic endpoint showing KV cache slot states.

## Architecture

```
┌─────────────────────────────────────────────┐
│              Hummingbird HTTP                │
│          /v1/chat/completions               │
├─────────────────────────────────────────────┤
│           InferenceEngine Protocol           │
├──────────────────┬──────────────────────────┤
│   LlamaEngine    │       MLXEngine          │
│  (llama.cpp C)   │   (mlx-swift-lm)         │
│  GGUF models     │   HuggingFace models     │
│  Continuous Batch│   ModelContainer actor    │
├──────────────────┴──────────────────────────┤
│              Apple Metal GPU                 │
└─────────────────────────────────────────────┘
```

## Hardware Recommendations

| Device | RAM | Recommended Config |
|--------|-----|--------------------|
| Mac Studio M3 Ultra | 96 GB | `--slots 20`, Qwen3.5-9B |
| MacBook Pro M3 Max | 36 GB | `--slots 8`, Qwen3.5-9B |
| Mac Mini M4 | 16 GB | `--slots 3`, Qwen3-8B (MLX) |

## Roadmap

- [ ] MLX backend migration to mlx-swift-lm 0.2x+ loader API (currently disabled at startup)
- [ ] Streaming responses (SSE) on `/v1/chat/completions` — benchmark scripts depend on this for TTFT
- [ ] Unify slot priority lanes (realtime / high / normal / low / batch) across HTTP path and Job dispatcher
- [ ] Replace handcrafted JSON in `/slots`, `/v1/memory`, `/v1/cluster/status`, `/v1/stats` with `Codable` encoders
- [ ] AuthN/AuthZ for cluster mode (currently binds `0.0.0.0` with no token check)
- [ ] Qwen3.5 MLX batch inference (blocked on MLX backend migration)
- [ ] Weight-shared 20-parallel inference
- [ ] arXiv paper

## Use Cases

- **Healthcare** -- local SOAP note generation with patient data privacy
- **Enterprise** -- privacy-sensitive document processing without cloud APIs
- **Multi-Agent** -- local AI agent orchestration with concurrent inference
- **Development** -- fast local LLM for coding assistants and RAG pipelines

## License

[MIT](LICENSE)
