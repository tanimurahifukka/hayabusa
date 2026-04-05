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
