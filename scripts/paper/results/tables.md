# KAJIBA Paper Tables

## Table 1: Hayabusa vs Ollama Performance Comparison

| Target | Conc. | Avg (ms) | P95 (ms) | TTFT (ms) | tok/s | req/s |
|--------|-------|----------|----------|-----------|-------|-------|
| Hayabusa | 1 | 10811 | 0 | 10811 | 111.2 | 0.87 |
| Ollama | 1 | 29488 | 0 | 29488 | 45.5 | 0.35 |
| Hayabusa | 4 | 10971 | 0 | 10971 | 122.8 | 0.96 |
| Ollama | 4 | 28970 | 0 | 28970 | 46.4 | 0.36 |
| Hayabusa | 8 | 11184 | 0 | 11184 | 122.1 | 0.95 |
| Ollama | 8 | 29004 | 0 | 29004 | 46.4 | 0.36 |
| Hayabusa | 16 | 11568 | 0 | 11568 | 120.0 | 0.94 |
| Ollama | 16 | 29020 | 0 | 29020 | 46.5 | 0.36 |

## Table 2: MLX vs llama.cpp Memory Usage

| Backend | Model Size | RSS (MB) | tok/s | TTFT (ms) |
|---------|-----------|----------|-------|-----------|
| ? | ? | 0 | 118.2 | 11419 |
| ? | ? | 0 | 124.0 | 9267 |
| ? | ? | 0 | 133.9 | 10513 |
| ? | ? | 0 | 136.9 | 8351 |
| ? | ? | 0 | 133.4 | 10565 |
| ? | ? | 0 | 136.3 | 8778 |
| ? | ? | 0 | 133.6 | 10551 |
| ? | ? | 0 | 136.4 | 7582 |

## Table 3: Uzu Cluster Scaling Performance

| Target | Conc. | Avg (ms) | P50 (ms) | P95 (ms) | tok/s | req/s |
|--------|-------|----------|----------|----------|-------|-------|
| (no data) | - | - | - | - | - | - |

## Table 4: Specialist vs Generalist Accuracy

| Domain | Specialist Avg | Generalist Avg | Spec. Win Rate | Tie Rate |
|--------|---------------|----------------|----------------|----------|
| (no data) | - | - | - | - |

## Table 5: Token Cost Reduction (Claude-only vs KAJIBA)

| Metric | Claude-only | KAJIBA |
|--------|-------------|--------|
| Total Tokens | 35,165 | 26,962 |
| Input Tokens | 2,685 | 1,472 |
| Output Tokens | 32,480 | 25,490 |
| Cost (USD) | $2.4763 | $1.9338 |
| Token Reduction | - | 23.3% |
| Cost Reduction | - | 21.9% |
| Cost Saved | - | $0.5424 |

Routing: 61 local, 39 escalate (61% local)

## Table 6: Saku Compression Effect

| Group | Count | Reduction | Similarity | Latency (ms) |
|-------|-------|-----------|------------|--------------|
| (no data) | - | - | - | - |
