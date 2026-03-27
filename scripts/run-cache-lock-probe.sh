#!/usr/bin/env bash
set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

export BASE_URL="${BASE_URL:-http://localhost:8080}"
export PROMETHEUS_URL="${PROMETHEUS_URL:-http://localhost:9090}"
export K6_PROMETHEUS_RW_SERVER_URL="${K6_PROMETHEUS_RW_SERVER_URL:-${PROMETHEUS_URL}/api/v1/write}"
export K6_PROMETHEUS_RW_PUSH_INTERVAL="${K6_PROMETHEUS_RW_PUSH_INTERVAL:-5s}"
export K6_PROMETHEUS_RW_TREND_STATS="${K6_PROMETHEUS_RW_TREND_STATS:-p(90),p(95),avg,max}"

export TOTAL_VUS="${TOTAL_VUS:-40}"
export LIVE_FRAC="${LIVE_FRAC:-0.25}"
export DURATION="${DURATION:-2m}"
export LOCK_PROBE_RATE="${LOCK_PROBE_RATE:-5}"
export LOCK_PROBE_SPIKE="${LOCK_PROBE_SPIKE:-80}"
export LOCK_PROBE_PREALLOCATED_VUS="${LOCK_PROBE_PREALLOCATED_VUS:-80}"
export LOCK_PROBE_MAX_VUS="${LOCK_PROBE_MAX_VUS:-400}"
export HOT_VOD_TITLE="${HOT_VOD_TITLE:-movie1}"
export HOT_VOD_SEGMENT="${HOT_VOD_SEGMENT:-0007}"
export HOT_VOD_VARIANT="${HOT_VOD_VARIANT:-720p}"

cd "${PROJECT_ROOT}"

echo "Running cache-lock probe against ${BASE_URL}"
echo "Prometheus remote-write target: ${K6_PROMETHEUS_RW_SERVER_URL}"
echo "Hot VOD object: /vod/${HOT_VOD_TITLE}/seg_${HOT_VOD_SEGMENT}.ts?variant=${HOT_VOD_VARIANT}"
echo "Lock probe rates: base=${LOCK_PROBE_RATE}/s spike=${LOCK_PROBE_SPIKE}/s"

exec k6 run -o experimental-prometheus-rw k6/smoke.js "$@"
