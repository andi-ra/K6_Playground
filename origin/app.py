from __future__ import annotations

import hashlib
import os
import random
import re
import socket
import time
from typing import Any

from fastapi import FastAPI, Request, Response
from fastapi.responses import PlainTextResponse
from prometheus_client import CONTENT_TYPE_LATEST, Counter, Histogram, generate_latest

app = FastAPI(title="k6-playground-origin", version="1.0.0")

HOSTNAME = socket.gethostname()
PORT = int(os.getenv("PORT", "8000"))

REQUEST_COUNT = Counter(
    "origin_requests_total",
    "Total requests served by the origin app.",
    labelnames=("method", "path"),
)
REQUEST_LATENCY = Histogram(
    "origin_request_latency_seconds",
    "Latency of origin requests.",
    labelnames=("path",),
)
SEGMENT_NAME_RE = re.compile(r"seg_(\d+)\.ts$")
LIVE_WINDOW = 6
LIVE_TARGET_DURATION = 2
VOD_TARGET_DURATION = 4
VOD_SEGMENT_COUNT = 12
VIDEO_VARIANTS = (
    {"bandwidth": 1800000, "resolution": "960x540", "name": "540p"},
    {"bandwidth": 3500000, "resolution": "1280x720", "name": "720p"},
    {"bandwidth": 6200000, "resolution": "1920x1080", "name": "1080p"},
)


@app.middleware("http")
async def add_metrics(request: Request, call_next) -> Response:
    REQUEST_COUNT.labels(method=request.method, path=request.url.path).inc()
    started_at = time.perf_counter()
    response = await call_next(request)
    REQUEST_LATENCY.labels(path=request.url.path).observe(time.perf_counter() - started_at)
    return response


@app.get("/")
def root() -> dict[str, Any]:
    return {
        "service": "origin",
        "hostname": HOSTNAME,
        "port": PORT,
        "message": "Origin is ready behind edge.",
    }


@app.get("/healthz")
def healthz() -> dict[str, str]:
    return {"status": "ok"}


@app.get("/api/data")
def api_data(item_id: int = 0, size: int = 5, delay_ms: int = 50) -> dict[str, Any]:
    rng = random.Random(item_id)
    time.sleep(max(delay_ms, 0) / 1000)
    values = [round(rng.uniform(10.0, 100.0), 2) for _ in range(max(size, 1))]
    return {
        "item_id": item_id,
        "hostname": HOSTNAME,
        "edge_ready": True,
        "values": values,
        "summary": {
            "count": len(values),
            "min": min(values),
            "max": max(values),
            "avg": round(sum(values) / len(values), 2),
        },
    }


@app.get("/api/slow")
def api_slow(delay_ms: int = 250) -> dict[str, Any]:
    time.sleep(max(delay_ms, 0) / 1000)
    return {"status": "slow-ok", "delay_ms": delay_ms}


def _stable_seed(*parts: object) -> int:
    joined = ":".join(str(part) for part in parts)
    return int(hashlib.sha256(joined.encode("utf-8")).hexdigest()[:16], 16)


def _extract_segment_index(segment_name: str) -> int:
    match = SEGMENT_NAME_RE.fullmatch(segment_name)
    if match is None:
        return 1
    return max(int(match.group(1)), 1)


def _playlist_headers(kind: str, cache_control: str) -> dict[str, str]:
    return {
        "Cache-Control": cache_control,
        "Content-Type": "application/vnd.apple.mpegurl",
        "X-Media-Class": kind,
        "X-Origin-Host": HOSTNAME,
    }


def _segment_headers(kind: str, cache_control: str, bitrate_kbps: int) -> dict[str, str]:
    return {
        "Cache-Control": cache_control,
        "Content-Type": "video/mp2t",
        "X-Media-Class": kind,
        "X-Origin-Host": HOSTNAME,
        "X-Bitrate-Kbps": str(bitrate_kbps),
    }


def _live_media_sequence(channel: str) -> int:
    epoch_bucket = int(time.time() // LIVE_TARGET_DURATION)
    return epoch_bucket * LIVE_WINDOW + (_stable_seed(channel) % LIVE_WINDOW)


def _live_master_playlist(channel: str) -> str:
    lines = ["#EXTM3U", "#EXT-X-VERSION:3"]
    for variant in VIDEO_VARIANTS:
        lines.append(
            (
                "#EXT-X-STREAM-INF:"
                f"BANDWIDTH={variant['bandwidth']},"
                f"RESOLUTION={variant['resolution']},"
                "CODECS=\"avc1.4d401f,mp4a.40.2\""
            )
        )
        lines.append(f"/live/{channel}/live.m3u8?variant={variant['name']}")
    return "\n".join(lines) + "\n"


def _live_playlist(channel: str, variant: str) -> str:
    media_sequence = _live_media_sequence(channel)
    rng = random.Random(_stable_seed("live-playlist", channel, variant))
    lines = [
        "#EXTM3U",
        "#EXT-X-VERSION:3",
        f"#EXT-X-TARGETDURATION:{LIVE_TARGET_DURATION}",
        f"#EXT-X-MEDIA-SEQUENCE:{media_sequence}",
    ]

    for offset in range(LIVE_WINDOW):
        segment_index = media_sequence + offset
        duration = 1.6 + rng.random() * 0.6
        lines.append(f"#EXTINF:{duration:.3f},")
        lines.append(f"/live/{channel}/seg_{segment_index}.ts?variant={variant}")

    return "\n".join(lines) + "\n"


def _vod_master_playlist(title: str) -> str:
    lines = ["#EXTM3U", "#EXT-X-VERSION:3"]
    for variant in VIDEO_VARIANTS:
        lines.append(
            (
                "#EXT-X-STREAM-INF:"
                f"BANDWIDTH={variant['bandwidth']},"
                f"RESOLUTION={variant['resolution']},"
                "CODECS=\"avc1.4d401f,mp4a.40.2\""
            )
        )
        lines.append(f"/vod/{title}/playlist.m3u8?variant={variant['name']}")
    return "\n".join(lines) + "\n"


def _vod_playlist(title: str, variant: str) -> str:
    rng = random.Random(_stable_seed("vod-playlist", title, variant))
    lines = [
        "#EXTM3U",
        "#EXT-X-VERSION:3",
        f"#EXT-X-TARGETDURATION:{VOD_TARGET_DURATION}",
        "#EXT-X-PLAYLIST-TYPE:VOD",
        "#EXT-X-MEDIA-SEQUENCE:1",
    ]

    for segment_index in range(1, VOD_SEGMENT_COUNT + 1):
        duration = 3.6 + rng.random() * 0.7
        lines.append(f"#EXTINF:{duration:.3f},")
        lines.append(f"/vod/{title}/seg_{segment_index:04d}.ts?variant={variant}")

    lines.append("#EXT-X-ENDLIST")
    return "\n".join(lines) + "\n"


def _mock_segment_bytes(kind: str, asset_id: str, segment_index: int, variant: str) -> bytes:
    seed = _stable_seed(kind, asset_id, segment_index, variant)
    rng = random.Random(seed)
    bitrate_kbps = {"540p": 1800, "720p": 3500, "1080p": 6200}.get(variant, 2500)
    base_size = 16000 if kind == "live" else 24000
    payload_size = base_size + int(bitrate_kbps * (0.7 if kind == "live" else 1.4)) + rng.randint(0, 4096)
    chunk = f"{kind}|{asset_id}|{segment_index}|{variant}|{HOSTNAME}|".encode("utf-8")
    repeats = (payload_size // len(chunk)) + 1
    return (chunk * repeats)[:payload_size]


@app.get("/live/{channel}/master.m3u8")
def live_master(channel: str) -> PlainTextResponse:
    time.sleep(0.03)
    return PlainTextResponse(
        _live_master_playlist(channel),
        headers=_playlist_headers("live-master", "public, max-age=2"),
    )


@app.get("/live/{channel}/live.m3u8")
def live_playlist(channel: str, variant: str = "720p") -> PlainTextResponse:
    time.sleep(0.04)
    return PlainTextResponse(
        _live_playlist(channel, variant),
        headers=_playlist_headers("live-playlist", "public, max-age=1"),
    )


@app.get("/live/{channel}/{segment_name}")
def live_segment(channel: str, segment_name: str, variant: str = "720p") -> Response:
    segment_index = _extract_segment_index(segment_name)
    time.sleep(0.05 + ((segment_index % 4) * 0.01))
    bitrate_kbps = {"540p": 1800, "720p": 3500, "1080p": 6200}.get(variant, 2500)
    return Response(
        _mock_segment_bytes("live", channel, segment_index, variant),
        headers=_segment_headers("live-segment", "public, max-age=3", bitrate_kbps),
    )


@app.get("/vod/{title}/master.m3u8")
def vod_master(title: str) -> PlainTextResponse:
    time.sleep(0.02)
    return PlainTextResponse(
        _vod_master_playlist(title),
        headers=_playlist_headers("vod-master", "public, max-age=300"),
    )


@app.get("/vod/{title}/playlist.m3u8")
def vod_playlist(title: str, variant: str = "720p") -> PlainTextResponse:
    time.sleep(0.03)
    return PlainTextResponse(
        _vod_playlist(title, variant),
        headers=_playlist_headers("vod-playlist", "public, max-age=300"),
    )


@app.get("/vod/{title}/{segment_name}")
def vod_segment(title: str, segment_name: str, variant: str = "720p") -> Response:
    segment_index = _extract_segment_index(segment_name)
    time.sleep(0.02 + ((segment_index % 5) * 0.005))
    bitrate_kbps = {"540p": 1800, "720p": 3500, "1080p": 6200}.get(variant, 2500)
    return Response(
        _mock_segment_bytes("vod", title, segment_index, variant),
        headers=_segment_headers("vod-segment", "public, max-age=3600, immutable", bitrate_kbps),
    )


@app.get("/metrics")
def metrics() -> Response:
    return Response(generate_latest(), media_type=CONTENT_TYPE_LATEST)
