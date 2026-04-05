# 2. Related Work

## 2.1 Local LLM Inference

**Ollama** provides a user-friendly interface for running LLMs locally, with recent
v0.19+ adding MLX backend support for Apple Silicon. However, Ollama's architecture
prioritizes compatibility over performance, resulting in higher memory usage and
suboptimal throughput for concurrent workloads.

**llama.cpp** is the de facto standard for local LLM inference, supporting GGUF
quantized models across platforms. While highly optimized for CPU and CUDA, its
Metal backend underutilizes Apple Silicon's unified memory architecture.

**MLX** (Apple) provides a NumPy-like framework specifically designed for Apple
Silicon, leveraging unified memory for efficient model loading and inference.
Hayabusa builds on MLX to provide a production-ready server with OpenAI-compatible
API endpoints.

## 2.2 Distributed Inference

**vLLM** and **TensorRT-LLM** provide high-throughput inference for datacenter
GPUs with PagedAttention and continuous batching. These systems assume homogeneous
GPU clusters and are not designed for heterogeneous edge devices.

**Petals** enables collaborative inference across consumer hardware but relies on
internet connectivity and introduces trust assumptions.

Uzu differs by targeting local-network clusters of Apple Silicon devices with
bandwidth-first routing that accounts for heterogeneous memory and compute capabilities.

## 2.3 Prompt Compression

**LLMLingua** and **Selective Context** propose attention-based token pruning for
prompt compression. These approaches require running the full model to compute
attention scores, adding latency.

Saku takes a simpler approach: using a small local model to rewrite prompts concisely,
trading compression ratio for lower latency and implementation simplicity.

## 2.4 Hybrid Local-Cloud Systems

Prior work on hybrid inference includes **SpecInfer** (speculative decoding with
local draft models) and **Edge-Cloud Collaboration** frameworks. KAJIBA's routing
approach is complementary, focusing on task-level routing rather than token-level
speculation.
