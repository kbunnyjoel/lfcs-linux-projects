# Project 2: System Monitoring Dashboard

## Overview
A portable monitoring tool that collects CPU, memory, disk, load averages, and basic process checks. It writes results in **text**, **JSON**, and **Prometheus** formats and evaluates simple thresholds for alerting.

## Features
- Linux-only, runnable on macOS via Docker
- Outputs: text (`latest.txt`), JSON (`latest.json`), Prometheus (`latest.prom`)
- Threshold alerts (warns in console)
- Environment-based config via `env/dev.env` and `env/prod.env`
- Per-mount disk usage monitoring (configurable via DISK_MOUNTS)
- Optional top process collection (toggle with TOP_PROCS_ENABLE in env)
- Docker-based workflow with Makefile targets
- Live Prometheus metrics HTTP endpoint (`/metrics` on :9100)
- Pretty JSON formatting via containerized Python

## Usage
```bash
cd project2-system-monitor/setup

# Development (verbose, all formats)
./install.sh dev


# Production-like (json/prom outputs)
./install.sh prod

# Example: Enable top processes on the fly
TOP_PROCS_ENABLE=true TOP_PROCS=3 ./install.sh prod

## Docker / Makefile Workflow

# Build and run one-shot collection (writes to outputs/)
make docker-run ENV=dev

# Pretty-print the JSON output (no local Python needed)
make pretty-json

# Run live Prometheus metrics server (default: Python server)
make metrics-server ENV=dev

# Use netcat variant instead of Python:
make metrics-server ENV=dev SERVER_IMPL=nc

Then scrape at: http://localhost:9100/metrics
```

## Prometheus Scrape Config

Add the following job to your `prometheus.yml`:

```yaml
scrape_configs:
  - job_name: 'system-monitor'
    static_configs:
      - targets: ['localhost:9100']
```

- If Prometheus runs inside another container on Docker Desktop, use `host.docker.internal:9100` instead of `localhost:9100`.
- Replace `localhost` with the appropriate host/IP if Prometheus runs elsewhere.

## Summary of Achievements

- Linux-only collectors, with Docker workflow for macOS hosts
- Outputs in multiple formats: text, JSON, Prometheus
- Threshold-based alerts for CPU, memory, and disk
- Environment configs (`dev.env` and `prod.env`) with different thresholds and formats
- Advanced options:
  - Per-mount disk usage monitoring (`DISK_MOUNTS`)
  - Optional top process collection (`TOP_PROCS_ENABLE`)
- Live metrics endpoint for Prometheus scraping
- Makefile-driven UX: docker-run, pretty-json, metrics-server
