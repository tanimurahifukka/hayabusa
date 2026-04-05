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
