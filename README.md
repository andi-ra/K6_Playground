# K6 Playground

This playground gives you one Docker Compose project with:

- `workspace`: the devcontainer and main driver, with `k6`, Python, JupyterLab, and Docker CLI.
- `edge`: an OpenResty reverse proxy with Lua instrumentation, cache policy probes, and Prometheus metrics.
- `origin`: a small FastAPI app with sample endpoints and Prometheus metrics.
- `prometheus`: stores origin scrape data and accepts k6 remote-write metrics.

The stack is designed for Windows with Docker Desktop using Linux containers. WSL2-backed Docker Desktop is the smoothest option.

## Project Layout

```text
.
|-- .devcontainer/
|-- docker-compose.yml
|-- edge/
|-- k6/
|-- origin/
|-- prometheus/
|-- python/
`-- scripts/
```

## Option 1: Open It As A Devcontainer

1. Open this folder in VS Code.
2. Make sure Docker Desktop is running in Linux container mode.
3. Run `Dev Containers: Reopen in Container`.

When the devcontainer comes up, VS Code uses the same `docker-compose.yml` and starts:

- `workspace`
- `origin`
- `edge`
- `prometheus`

JupyterLab is started automatically inside `workspace` and is exposed on `http://localhost:8888`.

## Option 2: Start It Manually With Docker Compose

From the project root:

```bash
docker compose up -d --build
docker compose exec workspace bash
```

That drops you into the same `workspace` container the devcontainer uses.

## Endpoints

- Edge: `http://localhost:8080`
- Edge metrics: `http://localhost:8080/metrics`
- OpenResty Lua transform endpoint: `http://localhost:8080/openresty/lua/transform`
- OpenResty Lua policy endpoint: `http://localhost:8080/openresty/lua/policy`
- Metadata service: `http://localhost:9100/metadata`
- Kafka mock event sink: `http://localhost:9300/events`
- Origin: `http://localhost:8000`
- Prometheus UI: `http://localhost:9090`
- JupyterLab: `http://localhost:8888`

## Run A K6 Test

Inside `workspace`:

```bash
bash scripts/run-smoke.sh
```

That sends k6 metrics to Prometheus using the experimental Prometheus remote-write output.

To override the load profile:

```bash
TOTAL_VUS=20 DURATION=2m bash scripts/run-smoke.sh
```

To exercise the OpenResty Lua/runtime path without mixing it into the baseline cache notebook:

```bash
TOTAL_VUS=20 \
OPENRESTY_VUS=10 \
OPENRESTY_BURST_RATE=5 \
OPENRESTY_BURST_SPIKE=40 \
OPENRESTY_BURST_BASE_DURATION=15s \
OPENRESTY_BURST_SPIKE_DURATION=15s \
OPENRESTY_BURST_RECOVERY_DURATION=15s \
bash scripts/run-smoke.sh
```

## Query Prometheus With Python

Inside `workspace`:

```bash
python python/examples/query_prometheus.py
```

For a quick slowdown attribution snapshot without opening Jupyter:

```bash
python python/examples/query_openresty_attribution.py
```

Or open the notebook:

- `python/notebooks/k6_prometheus_analysis.ipynb`
- `python/notebooks/openresty_edge_analysis.ipynb`
- `python/notebooks/openresty_external_io_analysis.ipynb`

## PromQL Examples For Live And VOD

Use these in the Prometheus UI at `http://localhost:9090` after running the smoke test from Codespaces or the workspace container.

Request rate by object type:

```promql
sum by (name) (rate(k6_http_reqs_total[1m]))
```

Request rate for live traffic only:

```promql
sum by (name) (
  rate(k6_http_reqs_total{name=~"live_master|live_playlist|live_segment"}[1m])
)
```

Request rate for VOD traffic only:

```promql
sum by (name) (
  rate(k6_http_reqs_total{name=~"vod_manifest|vod_playlist|vod_segment"}[1m])
)
```

Baseline cache-only request rate:

```promql
sum by (name) (
  rate(k6_http_reqs_total{lab="edge_cache_baseline"}[1m])
)
```

OpenResty-only request rate:

```promql
sum by (name) (
  rate(k6_http_reqs_total{lab="openresty_runtime"}[1m])
)
```

OpenResty edge request rate by Lua target:

```promql
sum by (route_family, target_kind) (
  rate(openresty_edge_requests_total[1m])
)
```

OpenResty edge request p95:

```promql
histogram_quantile(
  0.95,
  sum by (le, route_family, target_kind) (
    rate(openresty_edge_request_duration_seconds_bucket[5m])
  )
)
```

OpenResty access/content phase p95:

```promql
histogram_quantile(
  0.95,
  sum by (le, route_family, target_kind) (
    rate(openresty_edge_lua_access_duration_seconds_bucket[5m])
  )
)
```

```promql
histogram_quantile(
  0.95,
  sum by (le, route_family, target_kind) (
    rate(openresty_edge_lua_content_duration_seconds_bucket[5m])
  )
)
```

OpenResty header-filter phase p95:

```promql
histogram_quantile(
  0.95,
  sum by (le, target_kind) (
    rate(openresty_edge_header_filter_duration_seconds_bucket[5m])
  )
)
```

OpenResty metadata fetch rate:

```promql
sum by (target_kind, outcome) (
  rate(openresty_edge_metadata_requests_total[1m])
)
```

OpenResty metadata fetch p95:

```promql
histogram_quantile(
  0.95,
  sum by (le, target_kind, outcome) (
    rate(openresty_edge_metadata_duration_seconds_bucket[5m])
  )
)
```

OpenResty Redis connect p95 by phase:

```promql
histogram_quantile(
  0.95,
  sum by (le, target_kind, phase, outcome) (
    rate(openresty_edge_redis_connect_duration_seconds_bucket[5m])
  )
)
```

OpenResty Redis command p95 by phase and operation:

```promql
histogram_quantile(
  0.95,
  sum by (le, target_kind, phase, operation, outcome) (
    rate(openresty_edge_redis_command_duration_seconds_bucket[5m])
  )
)
```

Kafka-mock publish p95:

```promql
histogram_quantile(
  0.95,
  sum by (le, target_kind, outcome) (
    rate(openresty_edge_kafka_mock_publish_duration_seconds_bucket[5m])
  )
)
```

Current p95 latency by object type:

```promql
{
  __name__=~"k6_http_req_duration_p95"
}
```

Average latency by object type:

```promql
{
  __name__=~"k6_http_req_duration_avg"
}
```

Live vs VOD p95 comparison:

```promql
k6_http_req_duration_p95{name=~"live_master|live_playlist|live_segment|vod_manifest|vod_segment"}
```

Failure rate by object type:

```promql
k6_http_req_failed_rate{name=~"live_master|live_playlist|live_segment|vod_manifest|vod_segment"}
```

Check pass rate by object type:

```promql
k6_checks_rate{kind=~"live_master|live_playlist|live_segment|vod_manifest|vod_segment"}
```

Current active VUs:

```promql
k6_vus
```

Iterations per second:

```promql
rate(k6_iterations_total[1m])
```

Latency SLO spot checks:

```promql
k6_http_req_duration_p95{name="live_segment"}
```

```promql
k6_http_req_duration_p95{name="vod_segment"}
```

If you want a single high-signal dashboard starter, begin with:

```promql
sum by (name) (rate(k6_http_reqs_total[1m]))
```

```promql
k6_http_req_duration_p95{name=~"live_master|live_playlist|live_segment|vod_manifest|vod_segment"}
```

```promql
k6_http_req_failed_rate{name=~"live_master|live_playlist|live_segment|vod_manifest|vod_segment"}
```

## Notes For Windows

- Keep the folder on a path Docker Desktop can mount.
- If bind-mount performance is poor from `C:\`, moving the repo under WSL can help.
- The compose file mounts `/var/run/docker.sock` into `workspace` so you can run Docker commands from inside the devcontainer or the workspace container.
