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
