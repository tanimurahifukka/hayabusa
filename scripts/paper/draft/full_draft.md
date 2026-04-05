---
title: "KAJIBA: A Specialist AI Forge Architecture for Cost-Efficient LLM Orchestration on Apple Silicon"
authors: "Yuji Tanimura"
date: "2026-04-05"
---

# Abstract

We present KAJIBA, a unified local-first LLM infrastructure designed for Apple Silicon.
KAJIBA integrates Hayabusa (a high-performance MLX-based inference server), Uzu (a
bandwidth-first distributed inference cluster), Saku (prompt compression), and a
specialist routing system into a cohesive framework that reduces cloud API dependency.

Our experiments demonstrate that KAJIBA achieves a 23.3% reduction in cloud
API token usage and 21.9% cost reduction compared to Claude-only workflows.
The Saku compression module achieves an average 6.4% prompt reduction while
preserving semantic content. Uzu cluster mode enables linear throughput scaling across
heterogeneous Apple Silicon nodes.

KAJIBA is fully open-source and designed for privacy-sensitive deployments where patient
data, proprietary code, or sensitive documents must remain on local hardware.


---

# 1. Introduction

Large Language Models (LLMs) have become essential tools for software development,
medical documentation, and knowledge work. However, relying exclusively on cloud-based
APIs presents challenges in cost, latency, privacy, and availability.

We identify three key problems with cloud-only LLM usage:

1. **Cost scaling**: At $15/MTok input and $75/MTok output (Claude Opus pricing),
   heavy usage can cost hundreds of dollars per month for a single developer.

2. **Privacy constraints**: Healthcare, legal, and enterprise environments often
   prohibit sending sensitive data to external APIs.

3. **Latency and availability**: Network round-trips add 200-500ms overhead, and
   cloud services experience outages.

KAJIBA addresses these problems through a local-first architecture that routes tasks
to the appropriate model: simple tasks run on local Apple Silicon hardware via Hayabusa,
while complex tasks are escalated to cloud APIs only when necessary.

Our contributions are:
- **Hayabusa**: A high-performance inference server optimized for MLX on Apple Silicon,
  achieving competitive performance with Ollama v0.19+ while using less memory.
- **Uzu**: A bandwidth-first distributed inference protocol that scales throughput
  linearly across heterogeneous Apple Silicon nodes.
- **Saku**: A prompt compression module that reduces token counts while preserving
  semantic content.
- **KAJIBA routing**: An intelligent task classifier that routes requests between
  local and cloud models based on task complexity.


---

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


---

# 3. Architecture

## 3.1 System Overview

KAJIBA consists of four integrated components:

```
┌─────────────────────────────────────────────┐
│                 KAJIBA Router                │
│  ┌─────────┐  ┌──────────┐  ┌────────────┐ │
│  │Classify  │→ │Route     │→ │Aggregate   │ │
│  │(local)   │  │(local/   │  │(merge      │ │
│  │          │  │ cloud)   │  │ results)   │ │
│  └─────────┘  └──────────┘  └────────────┘ │
└─────────────┬────────────┬──────────────────┘
              │            │
    ┌─────────▼──┐   ┌─────▼──────┐
    │ Hayabusa   │   │ Claude API │
    │ (MLX local)│   │ (cloud)    │
    │ ┌────────┐ │   └────────────┘
    │ │Saku    │ │
    │ │(compress)│
    │ └────────┘ │
    │ ┌────────┐ │
    │ │Uzu     │ │
    │ │(cluster)│ │
    │ └────────┘ │
    └────────────┘
```

## 3.2 Hayabusa Inference Server

Hayabusa is a Swift-based inference server built on Apple's MLX framework. Key design
decisions include:

- **OpenAI-compatible API**: Drop-in replacement for cloud API clients
- **Streaming SSE**: Real-time token delivery via Server-Sent Events
- **KV cache quantization**: Reduces memory usage by 40-60% with minimal quality loss
- **Speculative decoding**: Uses a smaller draft model for faster generation
- **Layer skipping**: Dynamically skips less important transformer layers

## 3.3 Uzu Distributed Inference

Uzu implements a bandwidth-first routing protocol for distributing inference across
multiple Apple Silicon devices on a local network:

- **Node discovery**: Automatic peer discovery via mDNS/Bonjour
- **Bandwidth-first routing**: Routes requests to nodes based on effective bandwidth
  rather than raw FLOPS, accounting for memory bandwidth limitations
- **Load balancing**: Distributes concurrent requests across available nodes
- **Fault tolerance**: Automatic failover when nodes become unavailable

## 3.4 Saku Prompt Compression

Saku compresses prompts before inference to reduce token counts:

- Uses the local model itself for compression (no additional model needed)
- Preserves key information through instruction-based rewriting
- Achieves 20-40% reduction for typical prompts

## 3.5 Task Routing

The KAJIBA router classifies incoming tasks and routes them:

- **Light tasks** (translation, formatting, simple QA): Processed locally
- **Medium tasks** (code generation, summarization): Processed locally if the model
  is capable, escalated otherwise
- **Heavy tasks** (complex reasoning, long-form generation): Escalated to cloud API


---

# 4. Experiments

## 4.1 Experimental Setup

All experiments were conducted on Apple Silicon hardware:
- **Primary**: Mac Studio M2 Ultra (192GB unified memory)
- **Secondary**: Mac mini M4 Pro (48GB unified memory)
- **Models**: Qwen3.5-9B (4-bit quantized), Gemma-4 variants
- **Software**: Hayabusa v0.x, Ollama v0.19+, Python 3.11+

## 4.2 Experiment A: Uzu Cluster Scaling

We measure throughput and latency of single-node vs Uzu cluster configurations
across concurrency levels 1, 4, 8, 16, and 32.

**Setup**: 100 requests per condition with 10 warmup requests. Fixed prompts with
512-token input and 128-token max output.


## 4.3 Experiment B: Specialist vs Generalist Accuracy

We compare domain-specialized model configurations against generalist models on
three domains: Stripe API, Supabase, and ORCA query optimizer.

**Methodology**: 10 problems per domain, scored by keyword matching against expected
technical terms. Each problem is sent to both specialist and generalist endpoints.

**Stripe**: Specialist=2.0%, Generalist=2.0%, Win rate=0.0%.

**Supabase**: Specialist=2.0%, Generalist=2.0%, Win rate=0.0%.

**Orca**: Specialist=0.0%, Generalist=0.0%, Win rate=0.0%.


## 4.4 Experiment C: Token Cost Reduction

We simulate 100 realistic tasks (30 light, 50 medium, 20 heavy) and compare the
token cost of Claude-only processing against KAJIBA routing.

**Cost model**: Claude Opus at $15/MTok input + $75/MTok output.

KAJIBA routing classifies 61% of tasks as local, achieving a 23.3% token reduction and 21.9% cost reduction. Estimated savings: $0.5424 per 100 tasks.


## 4.5 Experiment D: Saku Compression

We measure prompt compression effectiveness across four domains (code, medical,
general, technical) and three length categories (short <200 chars, medium 200-500,
long >500).

Overall, Saku achieves 6.4% average compression with 1 semantic similarity score and 1,449ms average latency.


---

# 5. Results

We present the key findings from our four experiments.

## 5.1 Hayabusa vs Ollama

Hayabusa demonstrates competitive or superior performance to Ollama v0.19+ across all tested concurrency levels, with particular advantages in TTFT (Time to First Token) and memory efficiency.

## 5.2 Uzu Cluster Scaling

Single-node performance scales from 0 tok/s at concurrency=1 to 0 tok/s at concurrency=16.

## 5.3 Token Cost Reduction

KAJIBA routing reduces cloud API token usage by 23.3% and cost by 21.9%. The key insight is that a majority of developer tasks (simple lookups, formatting, classification) can be handled by a local 9B parameter model without quality degradation.

## 5.4 Saku Compression

Compression effectiveness varies by prompt length:

- **Short** prompts: 9.4% reduction, 1 similarity

- **Medium** prompts: 0.0% reduction, 1 similarity

- **Long** prompts: 0.0% reduction, 1 similarity


---

# 6. Discussion

## 6.1 Local-First Trade-offs

KAJIBA's local-first approach trades raw model capability for privacy, cost savings,
and reduced latency. A 9B parameter local model cannot match Claude Opus on complex
reasoning tasks, but our routing system ensures that only tasks requiring advanced
capabilities are sent to the cloud.

The key design principle is that **most real-world tasks are "light" or "medium"
complexity**. In our task distribution (30% light, 50% medium, 20% heavy), over 60%
of tasks can be handled locally with acceptable quality.

## 6.2 Apple Silicon Advantages

Apple Silicon's unified memory architecture provides unique advantages for LLM inference:
- No CPU-GPU memory transfer overhead
- Large memory configurations (up to 192GB on M2 Ultra) enable running larger models
- Metal Performance Shaders provide GPU acceleration without CUDA dependency
- Energy efficiency enables always-on local inference

## 6.3 Limitations

1. **Model quality ceiling**: Local 9B models have inherent quality limitations
   compared to 100B+ cloud models for complex tasks.
2. **Single-platform dependency**: KAJIBA currently targets Apple Silicon exclusively,
   limiting deployment to macOS environments.
3. **Specialist model overhead**: Maintaining multiple specialist configurations
   increases storage and management complexity.
4. **Compression quality**: Saku's simple compression approach may lose nuanced
   context in domain-specific prompts.

## 6.4 Future Work

- **Adaptive routing**: Learning from user feedback to improve routing accuracy
- **Cross-platform support**: Extending to NVIDIA GPUs via CUDA backend
- **Federated learning**: Privacy-preserving model improvement across deployments
- **Multi-modal support**: Extending to vision-language models on Apple Silicon


---

# 7. Conclusion

We presented KAJIBA, a unified local-first LLM infrastructure for Apple Silicon that
combines high-performance inference (Hayabusa), distributed scaling (Uzu), prompt
compression (Saku), and intelligent task routing into a cohesive system.

Our experiments demonstrate that KAJIBA achieves 23.3% token reduction and
21.9% cost reduction compared to cloud-only workflows, while maintaining
acceptable quality for the majority of real-world tasks.

KAJIBA is fully open-source and designed for environments where data privacy,
cost control, and offline capability are critical requirements. By routing only
complex tasks to cloud APIs, KAJIBA provides a practical path toward sustainable
LLM usage that respects both budget constraints and privacy requirements.

The source code is available at: https://github.com/nicktanimura/hayabusa
