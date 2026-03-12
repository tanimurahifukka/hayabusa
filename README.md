# Hayabusa

### Swift-Native LLM Inference Server for Apple Silicon

Hayabusa is a high-performance LLM inference server built from scratch in Swift, optimized for Apple Silicon. It delivers significantly faster inference than existing solutions by leveraging continuous batching, dual backends (llama.cpp + MLX), and zero Python overhead.

## Why Hayabusa?

| Problem | Existing Solution | Limitation |
|---------|------------------|------------|
| Local LLM serving | Ollama | Serial processing, no continuous batching |
| High-throughput inference | vLLM | No Apple Silicon / Metal support |
| Apple Silicon ML | MLX | No production HTTP server |

**Hayabusa fills the gap** -- a production-ready, OpenAI-compatible inference server purpose-built for Apple Silicon.

## Performance

### Hayabusa vs Ollama (Qwen3.5-9B, same model, same hardware)

| Metric | Hayabusa | Ollama | Improvement |
|--------|----------|--------|-------------|
| Avg Latency (conc=1) | 9,818 ms | 42,078 ms | **4.3x faster** |
| P95 Latency (conc=1) | 20,914 ms | 76,009 ms | **3.6x faster** |
| Throughput (conc=8) | 51.9 tok/s | 33.4 tok/s | **1.6x higher** |

> Mac Studio M3 Ultra 96GB, Qwen3.5-9B Q4_K_M, max_tokens=128

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
- **OpenAI-Compatible API** -- drop-in replacement (`/v1/chat/completions`)
- **Dual Backend** -- llama.cpp (GGUF) and MLX (HuggingFace) via `--backend` flag
- **Continuous Batching** -- concurrent request processing with shared KV cache
- **Priority Scheduler** -- realtime and batch priority lanes
- **Qwen3.5 Support** -- first MLX-backend server with Qwen3.5 (GatedDeltaNet hybrid architecture)

## Quick Start

### Prerequisites

- macOS 14+ (Sonnet or later)
- Apple Silicon (M1/M2/M3/M4)
- Xcode 15+ / Swift 5.10+

### Build llama.cpp

```bash
git clone https://github.com/ggml-org/llama.cpp vendor/llama.cpp
cd vendor/llama.cpp
cmake -B build -DGGML_METAL=ON -DBUILD_SHARED_LIBS=OFF
cmake --build build --config Release -j$(sysctl -n hw.ncpu)
cd ../..
```

### Download a Model

```bash
# GGUF (for llama.cpp backend)
huggingface-cli download unsloth/Qwen3.5-9B-GGUF Qwen3.5-9B-Q4_K_M.gguf \
  --local-dir models/

# MLX (auto-downloaded from HuggingFace on first run)
# Just pass the model ID: mlx-community/Qwen3.5-9B-MLX-4bit
```

### Build & Run

```bash
# Build
swift build

# Run with llama.cpp backend
.build/debug/Hayabusa models/Qwen3.5-9B-Q4_K_M.gguf --backend llama

# Run with MLX backend
.build/debug/Hayabusa mlx-community/Qwen3.5-9B-MLX-4bit --backend mlx

# Custom port and slot count
HAYABUSA_PORT=8081 .build/debug/Hayabusa models/Qwen3.5-9B-Q4_K_M.gguf \
  --backend llama --slots 8 --ctx-per-slot 4096
```

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

- [ ] Weight-shared 20-parallel inference
- [ ] Qwen3.5 MLX batch inference (pending mlx-swift-lm API)
- [ ] Streaming responses (SSE)
- [ ] arXiv paper

## Use Cases

- **Healthcare** -- local SOAP note generation with patient data privacy
- **Enterprise** -- privacy-sensitive document processing without cloud APIs
- **Multi-Agent** -- local AI agent orchestration with concurrent inference
- **Development** -- fast local LLM for coding assistants and RAG pipelines

## License

[MIT](LICENSE)
