#!/usr/bin/env bash
set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PORT="${PORT:-8000}"
HOST="${HOST:-0.0.0.0}"

cd "${PROJECT_ROOT}/origin"

exec uvicorn app:app \
  --host "${HOST}" \
  --port "${PORT}" \
  --reload
