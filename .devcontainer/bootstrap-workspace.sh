#!/usr/bin/env bash
set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
JUPYTER_PORT="${JUPYTER_PORT:-8888}"
LOG_DIR="${PROJECT_ROOT}/.devcontainer/logs"

mkdir -p "${LOG_DIR}"

if ! pgrep -f "jupyter-lab.*--port=${JUPYTER_PORT}" >/dev/null 2>&1; then
  nohup jupyter lab \
    --ip=0.0.0.0 \
    --port="${JUPYTER_PORT}" \
    --no-browser \
    --ServerApp.token='' \
    --ServerApp.password='' \
    --ServerApp.allow_origin='*' \
    --ServerApp.allow_remote_access=True \
    --ServerApp.root_dir="${PROJECT_ROOT}/python" \
    >"${LOG_DIR}/jupyter.log" 2>&1 &
fi

cd "${PROJECT_ROOT}"
exec sleep infinity
