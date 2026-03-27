from __future__ import annotations

import sys
from datetime import datetime, timedelta, timezone
from pathlib import Path

SRC_DIR = Path(__file__).resolve().parents[1] / "src"
if str(SRC_DIR) not in sys.path:
    sys.path.insert(0, str(SRC_DIR))

from prometheus_tools import instant_query, query_range


def main() -> None:
    end = datetime.now(timezone.utc)
    start = end - timedelta(minutes=15)

    rate_df = query_range("rate(k6_http_reqs_total[1m])", start, end)
    p95_df = query_range("k6_http_req_duration_p95", start, end)
    up_df = instant_query("up")

    print("Current scrape targets:")
    print(up_df.to_string(index=False))
    print()

    print("Recent k6 request rate samples:")
    print(rate_df.tail(10).to_string(index=False))
    print()

    print("Recent k6 p95 latency samples:")
    print(p95_df.tail(10).to_string(index=False))


if __name__ == "__main__":
    main()

