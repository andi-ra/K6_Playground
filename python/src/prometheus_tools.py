from __future__ import annotations

import os
from datetime import datetime, timezone
from typing import Any

import pandas as pd
import requests

DEFAULT_PROMETHEUS_URL = "http://localhost:9090"


def _resolve_prometheus_url(prometheus_url: str | None = None) -> str:
    if prometheus_url:
        return prometheus_url

    env_url = os.getenv("PROMETHEUS_URL")
    if env_url:
        return env_url

    return DEFAULT_PROMETHEUS_URL


def _request(
    path: str,
    params: dict[str, Any],
    prometheus_url: str | None = None,
) -> requests.Response:
    resolved_url = _resolve_prometheus_url(prometheus_url)

    try:
        response = requests.get(
            f"{resolved_url}{path}",
            params=params,
            timeout=30,
        )
        response.raise_for_status()
        return response
    except requests.HTTPError as exc:
        message = exc.response.text if exc.response is not None else str(exc)
        raise RuntimeError(
            f"Prometheus request failed at {resolved_url}{path} with params {params}: {message}"
        ) from exc
    except requests.RequestException as exc:
        raise RuntimeError(
            "Prometheus is not reachable at "
            f"{resolved_url}. In Codespaces, make sure the service is running and "
            "use PROMETHEUS_URL=http://localhost:9090 when launching from the workspace."
        ) from exc


def _normalize_timestamp(value: datetime | str) -> str:
    if isinstance(value, str):
        return value

    if value.tzinfo is None:
        value = value.replace(tzinfo=timezone.utc)

    return value.astimezone(timezone.utc).isoformat()


def _unwrap(payload: dict[str, Any]) -> list[dict[str, Any]]:
    if payload.get("status") != "success":
        raise RuntimeError(f"Prometheus request failed: {payload}")

    return payload.get("data", {}).get("result", [])


def instant_query(
    expression: str,
    prometheus_url: str | None = None,
) -> pd.DataFrame:
    response = _request(
        "/api/v1/query",
        params={"query": expression},
        prometheus_url=prometheus_url,
    )
    series = _unwrap(response.json())

    rows: list[dict[str, Any]] = []
    for item in series:
        timestamp, value = item["value"]
        row = {
            "timestamp": pd.to_datetime(timestamp, unit="s", utc=True),
            "value": float(value),
        }
        row.update(item.get("metric", {}))
        rows.append(row)

    return pd.DataFrame(rows)


def query_range(
    expression: str,
    start: datetime | str,
    end: datetime | str,
    step: str = "15s",
    prometheus_url: str | None = None,
) -> pd.DataFrame:
    response = _request(
        "/api/v1/query_range",
        params={
            "query": expression,
            "start": _normalize_timestamp(start),
            "end": _normalize_timestamp(end),
            "step": step,
        },
        prometheus_url=prometheus_url,
    )
    series = _unwrap(response.json())

    frames: list[pd.DataFrame] = []
    for item in series:
        frame = pd.DataFrame(item["values"], columns=["timestamp", "value"])
        frame["timestamp"] = pd.to_datetime(frame["timestamp"], unit="s", utc=True)
        frame["value"] = pd.to_numeric(frame["value"], errors="coerce")

        for key, value in item.get("metric", {}).items():
            frame[key] = value

        frames.append(frame)

    if not frames:
        return pd.DataFrame(columns=["timestamp", "value"])

    return pd.concat(frames, ignore_index=True)
