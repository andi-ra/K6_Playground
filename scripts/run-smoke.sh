#!/usr/bin/env bash
set -euo pipefail

PROMETHEUS_URL="${PROMETHEUS_URL:-http://prometheus:9090}"
BASE_URL="${BASE_URL:-http://edge}"
SCRIPT_PATH="${1:-k6/smoke.js}"
PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

if [[ "${SCRIPT_PATH}" != /* ]]; then
  SCRIPT_PATH="${PROJECT_ROOT}/${SCRIPT_PATH}"
fi

export BASE_URL
export K6_PROMETHEUS_RW_SERVER_URL="${K6_PROMETHEUS_RW_SERVER_URL:-${PROMETHEUS_URL}/api/v1/write}"
export K6_PROMETHEUS_RW_PUSH_INTERVAL="${K6_PROMETHEUS_RW_PUSH_INTERVAL:-5s}"
export K6_PROMETHEUS_RW_TREND_STATS="${K6_PROMETHEUS_RW_TREND_STATS:-p(90),p(95),avg,max}"

cd "${PROJECT_ROOT}"

echo "Running k6 against ${BASE_URL}"
echo "Prometheus remote-write target: ${K6_PROMETHEUS_RW_SERVER_URL}"

k6 run -o experimental-prometheus-rw "${SCRIPT_PATH}"
