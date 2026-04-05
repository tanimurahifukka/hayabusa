#!/usr/bin/env bash
# KAJIBA Paper — 全実験を順次実行するスクリプト
#
# Usage:
#   bash scripts/paper/run_all_experiments.sh
#   bash scripts/paper/run_all_experiments.sh --hayabusa-url http://localhost:8080

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
HAYABUSA_URL="${1:-http://localhost:8080}"
CLUSTER_URL="${2:-http://localhost:8081}"

echo "=================================================="
echo "KAJIBA Paper Experiments"
echo "=================================================="
echo "Hayabusa URL: ${HAYABUSA_URL}"
echo "Cluster URL:  ${CLUSTER_URL}"
echo "Script dir:   ${SCRIPT_DIR}"
echo "Started at:   $(date '+%Y-%m-%d %H:%M:%S')"
echo "=================================================="

TOTAL_START=$(date +%s)

# ── ヘルスチェック ────────────────────────────────────────────────────
echo ""
echo "[0/5] Health check..."
if curl -s --max-time 5 "${HAYABUSA_URL}/v1/models" > /dev/null 2>&1; then
    echo "  Hayabusa (single) is running."
else
    echo "  WARNING: Hayabusa at ${HAYABUSA_URL} is not responding."
    echo "  Some experiments may fail or use fallback mode."
fi

if curl -s --max-time 5 "${CLUSTER_URL}/v1/models" > /dev/null 2>&1; then
    echo "  Hayabusa (cluster) is running."
else
    echo "  INFO: Cluster at ${CLUSTER_URL} is not running. Exp A will run single-only."
fi

# ── Experiment A: Uzu Cluster ────────────────────────────────────────
echo ""
echo "=================================================="
echo "[1/5] Experiment A: Uzu Cluster Benchmark"
echo "=================================================="
EXP_START=$(date +%s)

python3 "${SCRIPT_DIR}/exp_a_uzu_cluster.py" \
    --single-url "${HAYABUSA_URL}" \
    --cluster-url "${CLUSTER_URL}" \
    --concurrencies 1 4 8 16 32 \
    --requests 100 \
    --warmup 10 \
    > /dev/null

EXP_END=$(date +%s)
echo "  Completed in $((EXP_END - EXP_START))s"

# ── Experiment B: Specialist Accuracy (3 domains) ─────────────────────
echo ""
echo "=================================================="
echo "[2/5] Experiment B: Specialist Accuracy"
echo "=================================================="
EXP_START=$(date +%s)

for DOMAIN in stripe supabase orca; do
    echo "  --- Domain: ${DOMAIN} ---"
    python3 "${SCRIPT_DIR}/exp_b_specialist_accuracy.py" \
        --domain "${DOMAIN}" \
        --specialist-url "${HAYABUSA_URL}" \
        --generalist-url "${HAYABUSA_URL}" \
        > /dev/null
done

EXP_END=$(date +%s)
echo "  Completed in $((EXP_END - EXP_START))s"

# ── Experiment C: Token Cost ──────────────────────────────────────────
echo ""
echo "=================================================="
echo "[3/5] Experiment C: Token Cost Reduction"
echo "=================================================="
EXP_START=$(date +%s)

python3 "${SCRIPT_DIR}/exp_c_token_cost.py" \
    --hayabusa-url "${HAYABUSA_URL}" \
    > /dev/null

EXP_END=$(date +%s)
echo "  Completed in $((EXP_END - EXP_START))s"

# ── Experiment D: Saku Compression ────────────────────────────────────
echo ""
echo "=================================================="
echo "[4/5] Experiment D: Saku Compression"
echo "=================================================="
EXP_START=$(date +%s)

python3 "${SCRIPT_DIR}/exp_d_saku_compression.py" \
    --hayabusa-url "${HAYABUSA_URL}" \
    --samples 100 \
    > /dev/null

EXP_END=$(date +%s)
echo "  Completed in $((EXP_END - EXP_START))s"

# ── Generate Tables ──────────────────────────────────────────────────
echo ""
echo "=================================================="
echo "[5/5] Generating Paper Tables"
echo "=================================================="
EXP_START=$(date +%s)

python3 "${SCRIPT_DIR}/generate_paper_tables.py" \
    --format both

EXP_END=$(date +%s)
echo "  Completed in $((EXP_END - EXP_START))s"

# ── 完了 ──────────────────────────────────────────────────────────────
TOTAL_END=$(date +%s)
TOTAL_TIME=$((TOTAL_END - TOTAL_START))

echo ""
echo "=================================================="
echo "All experiments completed!"
echo "Total time: ${TOTAL_TIME}s ($(( TOTAL_TIME / 60 ))m $(( TOTAL_TIME % 60 ))s)"
echo "Results:    ${SCRIPT_DIR}/results/"
echo "Tables:     ${SCRIPT_DIR}/results/tables.md"
echo "            ${SCRIPT_DIR}/results/tables.tex"
echo "Finished at: $(date '+%Y-%m-%d %H:%M:%S')"
echo "=================================================="
