#!/bin/sh
# Launch the MLX Breeze TTS API natively on macOS Apple Silicon.
# No Docker required — runs directly with Metal GPU acceleration.
#
#   ./runtimes/mlx/run.sh                  # uses .env
#   BREEZE_PORT=8080 ./runtimes/mlx/run.sh # override port
set -eu

cd "$(dirname "$0")/../.."

# Source .env if present
if [ -f .env ]; then
    set -a
    . ./.env
    set +a
fi

HOST="${BREEZE_BIND:-0.0.0.0}"
PORT="${BREEZE_PORT:-7860}"

exec python3 runtimes/mlx/mlx_api.py
