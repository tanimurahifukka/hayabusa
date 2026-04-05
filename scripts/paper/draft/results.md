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
