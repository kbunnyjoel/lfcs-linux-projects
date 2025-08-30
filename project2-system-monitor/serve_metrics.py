

#!/usr/bin/env python3
"""Tiny HTTP server that exposes Prometheus metrics at /metrics.

On each scrape request it re-runs `setup/install.sh <ENV>` to refresh metrics,
then serves the contents of `outputs/latest.prom`.

Usage:
  MON_ENV=dev python3 serve_metrics.py
  # then curl http://localhost:9100/metrics

Environment variables:
  MON_ENV       Which env file to use (e.g. dev, prod). Default: "dev"
  METRICS_PORT  Port to listen on. Default: 9100
"""
from __future__ import annotations
import http.server
import os
import pathlib
import socketserver
import subprocess
import sys
from typing import Tuple

ROOT = pathlib.Path(__file__).resolve().parent
ENV = os.environ.get("MON_ENV", "dev")
PORT = int(os.environ.get("METRICS_PORT", "9100"))
OUTPUT = ROOT / "outputs" / "latest.prom"
SETUP_SCRIPT = ROOT / "setup" / "install.sh"

class MetricsHandler(http.server.BaseHTTPRequestHandler):
    def _write(self, status: int, body: str, headers: Tuple[Tuple[str, str], ...]):
        self.send_response(status)
        for k, v in headers:
            self.send_header(k, v)
        self.end_headers()
        self.wfile.write(body.encode("utf-8"))

    def do_GET(self):  # noqa: N802 (BaseHTTPRequestHandler API)
        if self.path.rstrip('/') == "/metrics":
            # Rebuild metrics on each scrape. We swallow script output but keep exit code.
            try:
                subprocess.run(
                    [str(SETUP_SCRIPT), ENV],
                    check=False,
                    stdout=subprocess.PIPE,
                    stderr=subprocess.PIPE,
                )
            except Exception as e:  # very defensive
                body = f"# error running install.sh: {e}\n"
                self._write(
                    500,
                    body,
                    (
                        ("Content-Type", "text/plain; charset=utf-8"),
                        ("Cache-Control", "no-store"),
                    ),
                )
                return

            if OUTPUT.exists():
                body = OUTPUT.read_text(encoding="utf-8")
                status = 200
                headers = (
                    ("Content-Type", "text/plain; version=0.0.4; charset=utf-8"),
                    ("Cache-Control", "no-store"),
                )
            else:
                body = "# no metrics available yet\n"
                status = 200
                headers = (
                    ("Content-Type", "text/plain; version=0.0.4; charset=utf-8"),
                    ("Cache-Control", "no-store"),
                )

            self._write(status, body, headers)
            return

        # Not found
        self._write(404, "not found\n", (("Content-Type", "text/plain; charset=utf-8"),))

    def log_message(self, fmt: str, *args):  # silence default access log
        return


def main() -> int:
    # Basic sanity checks
    if not SETUP_SCRIPT.exists():
        print(f"[error] setup script missing: {SETUP_SCRIPT}", file=sys.stderr)
        return 1

    with socketserver.TCPServer(("", PORT), MetricsHandler) as httpd:
        print(f"Serving Prometheus metrics on :{PORT} (env={ENV})")
        try:
            httpd.serve_forever()
        except KeyboardInterrupt:
            print("\n[info] Shutting down")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
