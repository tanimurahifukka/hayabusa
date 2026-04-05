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
