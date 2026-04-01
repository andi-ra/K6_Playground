from __future__ import annotations

import sys
from datetime import datetime, timedelta, timezone
from pathlib import Path

import pandas as pd

SRC_DIR = Path(__file__).resolve().parents[1] / "src"
if str(SRC_DIR) not in sys.path:
    sys.path.insert(0, str(SRC_DIR))

from prometheus_tools import instant_query, query_range

BASELINE_LAB = "edge_cache_baseline"
OPENRESTY_LAB = "openresty_runtime"
EDGE_TARGET_MAP = {
    "live_master": ("live", "live_master"),
    "live_playlist": ("live", "live_playlist"),
    "live_segment": ("live", "live_segment"),
    "vod_manifest": ("vod", "vod_manifest"),
    "vod_playlist": ("vod", "vod_playlist"),
    "vod_segment": ("vod", "vod_segment"),
    "openresty_transform": ("openresty", "lua_transform"),
    "openresty_policy": ("openresty", "lua_policy"),
    "openresty_gc_probe": ("openresty", "lua_transform"),
}
ORIGIN_PATTERNS = {
    "live_master": r"/live/.*/master\\.m3u8",
    "live_playlist": r"/live/.*/live\\.m3u8",
    "live_segment": r"/live/.*/seg_.*\\.ts",
    "vod_manifest": r"/vod/.*/master\\.m3u8",
    "vod_playlist": r"/vod/.*/playlist\\.m3u8",
    "vod_segment": r"/vod/.*/seg_.*\\.ts",
}


def q(expression: str, start: datetime, end: datetime, step: str = "15s") -> pd.DataFrame:
    return query_range(expression, start, end, step=step)


def latest_subset(frame: pd.DataFrame, group_cols: list[str], columns: list[str]) -> pd.DataFrame:
    if frame.empty:
        return pd.DataFrame(columns=columns)
    latest = frame.sort_values("timestamp").groupby(group_cols, dropna=False).tail(1).reset_index(drop=True)
    for column in columns:
        if column not in latest.columns:
            latest[column] = pd.NA
    return latest[columns].copy()


def with_ms(frame: pd.DataFrame) -> pd.DataFrame:
    if frame.empty:
        return frame.copy()
    enriched = frame.copy()
    enriched["value_ms"] = enriched["value"] * 1000.0
    return enriched


def classify(row: pd.Series) -> str:
    client_p95 = row.get("client_p95_ms")
    edge_p95 = row.get("edge_p95_ms")
    upstream_p95 = row.get("upstream_p95_ms")
    origin_p95 = row.get("origin_p95_ms")
    route_family = row.get("route_family")

    if pd.isna(client_p95):
        return "no_recent_client_signal"
    if route_family == "openresty":
        return "edge_openresty_path" if pd.notna(edge_p95) and edge_p95 >= 0.75 * client_p95 else "client_or_measurement_gap"
    if (
        pd.notna(upstream_p95)
        and pd.notna(edge_p95)
        and pd.notna(client_p95)
        and edge_p95 >= 0.70 * client_p95
        and upstream_p95 >= 0.70 * edge_p95
    ):
        return "origin" if pd.notna(origin_p95) and origin_p95 >= 0.70 * upstream_p95 else "upstream_or_origin_adjacent"
    if pd.notna(edge_p95) and edge_p95 >= 0.75 * client_p95:
        return "edge"
    if pd.notna(edge_p95) and client_p95 >= 1.25 * edge_p95:
        return "client_network_or_load_driver"
    return "mixed_or_low_signal"


def main() -> None:
    end = datetime.now(timezone.utc)
    start = end - timedelta(minutes=30)

    up_df = instant_query("up")
    client_p95_df = with_ms(q(f'k6_http_req_duration_p95{{lab=~"{BASELINE_LAB}|{OPENRESTY_LAB}"}}', start, end))
    edge_p95_df = with_ms(
        q(
            'histogram_quantile(0.95, sum by (le, route_family, target_kind) (rate(openresty_edge_request_duration_seconds_bucket[5m])))',
            start,
            end,
        )
    )
    upstream_p95_df = with_ms(
        q(
            'histogram_quantile(0.95, sum by (le, route_family, target_kind) (rate(openresty_edge_upstream_response_seconds_bucket[5m])))',
            start,
            end,
        )
    )

    origin_frames: list[pd.DataFrame] = []
    for origin_kind, pattern in ORIGIN_PATTERNS.items():
        frame = with_ms(
            q(
                f'histogram_quantile(0.95, sum by (le) (rate(origin_request_latency_seconds_bucket{{path=~"{pattern}"}}[5m])))',
                start,
                end,
            )
        )
        if not frame.empty:
            frame["name"] = origin_kind
            origin_frames.append(frame)

    origin_p95_df = pd.concat(origin_frames, ignore_index=True) if origin_frames else pd.DataFrame(columns=["timestamp", "name", "value_ms"])

    client_latest = latest_subset(client_p95_df, ["lab", "name"], ["lab", "name", "value_ms"]).rename(columns={"value_ms": "client_p95_ms"})
    client_latest["route_family"] = client_latest["name"].map(lambda value: EDGE_TARGET_MAP.get(value, (None, None))[0])
    client_latest["target_kind"] = client_latest["name"].map(lambda value: EDGE_TARGET_MAP.get(value, (None, None))[1])
    edge_latest = latest_subset(edge_p95_df, ["route_family", "target_kind"], ["route_family", "target_kind", "value_ms"]).rename(columns={"value_ms": "edge_p95_ms"})
    upstream_latest = latest_subset(upstream_p95_df, ["route_family", "target_kind"], ["route_family", "target_kind", "value_ms"]).rename(columns={"value_ms": "upstream_p95_ms"})
    origin_latest = latest_subset(origin_p95_df, ["name"], ["name", "value_ms"]).rename(columns={"value_ms": "origin_p95_ms"})

    summary_df = (
        client_latest
        .merge(edge_latest, on=["route_family", "target_kind"], how="left")
        .merge(upstream_latest, on=["route_family", "target_kind"], how="left")
        .merge(origin_latest, on="name", how="left")
    )
    summary_df["likely_bottleneck"] = summary_df.apply(classify, axis=1)
    summary_df = summary_df.sort_values(["lab", "client_p95_ms"], ascending=[True, False]).reset_index(drop=True)

    print("Current scrape targets:")
    print(up_df.to_string(index=False))
    print()

    print("Latest slowdown attribution snapshot:")
    print(summary_df.to_string(index=False))


if __name__ == "__main__":
    main()
