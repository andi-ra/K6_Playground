# K6 Playground

This playground gives you one Docker Compose project with:

- `workspace`: the devcontainer and main driver, with `k6`, Python, JupyterLab, and Docker CLI.
- `edge`: an `nginx` reverse proxy that fronts the origin service.
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
VUS=20 DURATION=2m bash scripts/run-smoke.sh
```

## Query Prometheus With Python

Inside `workspace`:

```bash
python python/examples/query_prometheus.py
```

Or open the notebook:

- `python/notebooks/k6_prometheus_analysis.ipynb`

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
  rate(k6_http_reqs_total{name=~"vod_manifest|vod_segment"}[1m])
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
