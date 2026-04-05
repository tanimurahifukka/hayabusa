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
