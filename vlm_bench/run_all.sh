#!/bin/bash
# Run the full bake-off: one model at a time, never parallel (GPU is shared
# with the user), 2s pause between models. Each model runs in its own process
# so RSS / Metal peak-memory numbers are clean.
set -uo pipefail
cd "$(dirname "$0")"
export HF_HOME=$PWD/models HF_HUB_OFFLINE=1

run() {
  echo "=============== $1 ==============="
  .venv/bin/python run_vlm_bench.py --model "$1" ${2:-} 2>&1 | grep -v "^Warning"
  sleep 2
}

run mlx-community/Qwen3-VL-4B-Instruct-4bit
run mlx-community/Qwen3.5-4B-4bit --no-think
run apple/FastVLM-1.5B
run apple/FastVLM-0.5B
echo "BENCH_ALL_DONE"
