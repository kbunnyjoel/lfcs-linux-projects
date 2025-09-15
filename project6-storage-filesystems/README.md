# Project 6 – Storage & Filesystems Watchdog

Simple bash utilities and tests to validate basic filesystem health for Linux. Sprint 1 focuses on an **on-demand check** for a path (exists & writable) with optional JSON output, runnable locally or in Docker with Bats tests.

---

## Repo layout

```
project6-storage-filesystems/
├─ env/
│  ├─ dev.env
│  └─ prod.env
├─ logs/
├─ outputs/
├─ src/
│  └─ fs.sh
├─ tests/
│  ├─ test_fs_basic.bats
│  └─ test_fs_real.bats
├─ Dockerfile
├─ Makefile
└─ README.md
```

---

## Sprint 1 scope

- CLI: `src/fs.sh check` with options:
  - `--path PATH` : filesystem path to validate
  - `--once`      : run once (no loop)
  - `--json`      : print JSON only to stdout
- Health logic: **healthy** if PATH exists and is writable; **unhealthy** otherwise
- Exit codes: `0` healthy, `1` unhealthy, `2` usage error
- Basic tests in Bats cover healthy/unhealthy and JSON output

---

## Usage

### Local (host)
```bash
# One-off check
src/fs.sh check --path /tmp

# JSON summary for automation
src/fs.sh check --path /tmp --json
```

### With environment presets
`env/dev.env` and `env/prod.env` can declare defaults consumed by `fs.sh`:
```bash
# env/dev.env (example)
FS_PATHS="/ /tmp /var/log"
FS_INTERVAL=30
FS_NOTIFY="stdout"
```
> In Sprint 1 the check uses `--path`; later sprints can add multi-path loops & notifications.

> **Note:** The production environment defaults in `env/prod.env` typically include hardened settings, such as enforced mount options for `/tmp` to enhance security and stability in production deployments.

For example, a typical `env/prod.env` might look like:
```bash
# env/prod.env (example)
FS_PATHS="/ /tmp /var/log"
FS_INTERVAL=60
FS_NOTIFY="syslog"
# Ensure /tmp is mounted securely:
FS_MOUNT_TMP_OPTS="nodev,nosuid,noexec"
# Example: /etc/fstab entry for /tmp should look like:
# tmpfs   /tmp   tmpfs   nodev,nosuid,noexec   0  0
```

---

## Test

### Prereqs
- Docker Desktop or compatible runtime

### Run
```bash
make test
```
This builds the image and runs all Bats tests in `tests/`. You should see all tests pass for Sprint 1.

To run tests with environment presets:
```bash
FS_ENV_FILE=env/dev.env make test
FS_ENV_FILE=env/prod.env make test
```

---

## JSON format
Example (healthy):
```json
{
  "timestamp": "2025-01-01T00:00:00Z",
  "path": "/tmp",
  "writable": true,
  "overall": "up"
}
```
Example (unhealthy):
```json
{
  "timestamp": "2025-01-01T00:00:00Z",
  "path": "/not/there",
  "writable": false,
  "overall": "down"
}
```

---

## Make targets
```bash
make build   # build Docker image
make test    # build + run bats tests
```


---

## Notes
- `fs.sh` prints **only JSON** to stdout when `--json` is used; informational logs go to stderr.
- The repo keeps `logs/` and `outputs/` for future sprints (rotation/archival, reports, etc.).
- Environment files (`env/dev.env`, `env/prod.env`) are automatically loaded unless overridden by setting the `FS_ENV_FILE` environment variable.

---

## Systemd Deployment

You can run `fs-check` as a scheduled systemd service and timer, even inside a Docker container. The repo includes example unit files:
- `deploy/systemd/fs-check.service`
- `deploy/systemd/fs-check.timer`

### Running `fs-check` as a systemd service and timer

The `fs-check` utility can be configured to run periodically using systemd timers and services. This allows automated, scheduled health checks on filesystem paths without manual intervention.

- The `fs-check.service` unit defines how to run the check command.
- The `fs-check.timer` unit schedules the periodic execution of the service.

This setup is suitable for both host Linux systems and containerized environments that support systemd.

### Running inside Docker

To use systemd in a container (such as the provided image), you can enable and start the timer and service as follows:

```bash
docker exec -it fsd2 bash -lc 'systemctl enable --now fs-check.timer'
docker exec -it fsd2 bash -lc 'systemctl status fs-check.service'
docker exec -it fsd2 bash -lc 'journalctl -u fs-check.service -n 20 --no-pager'
```

This will start the timer, which triggers the `fs-check` service on schedule, and you can view logs and status with the commands above.

### Validating systemd setup

When running systemd inside Docker or on a host, validate the following:

1. **Unit files load correctly** – use `systemctl cat fs-check.service` and `systemctl cat fs-check.timer` to inspect the loaded configuration.
2. **Service runs and logs JSON output** – check service status and logs to ensure the check runs successfully and outputs JSON with the correct exit codes.
3. **Timer schedules periodic runs** – use `systemctl list-timers` to verify the timer is active and firing at expected intervals.
4. **Environment overrides apply** – ensure environment variables from `/etc/project6/env` or other configured files are loaded by the service.

### Environment file handling

By default, the service loads environment variables from `env/prod.env` (via the `FS_ENV_FILE` variable). In production, you can override this by placing an environment file at `/etc/project6/env` inside the container or host system. This allows you to adjust settings without rebuilding the image or modifying the container.

For example, to override the default environment:

- Place your custom environment file at `/etc/project6/env` inside the container or host.
- The service will automatically pick it up and use those environment variables.

This provides flexibility for production deployments to customize paths, intervals, notification methods, and other settings.

### Strict vs relaxed mount option handling

Production deployments often enforce strict mount options for security, such as:

```bash
FS_EXPECT_OPTS="nodev,nosuid,noexec"
```

This variable requires that `/tmp` (or other monitored paths) be mounted with these options to be considered healthy. The associated checks help ensure hardened filesystem configurations.

In containerized environments, these strict mount options may not be present or applicable (because `/tmp` might be a virtual or overlay filesystem without these options). To accommodate this, you can relax the check by overriding `FS_EXPECT_OPTS` with an empty value in `/etc/project6/env`:

```bash
FS_EXPECT_OPTS=
```

This disables the strict mount option check inside the container, allowing the service to report healthy status even if the underlying filesystem does not support those options.

> **Note:** In production, administrators should restore strict mount options and environment settings to ensure hardened deployments and maintain security best practices.

---

## Sprint Roadmap (Future Work)

### Sprint 1 – Scaffold & Basic Health Check ✅
- Scaffold project layout and repo structure
- Implement minimal CLI: `fs.sh check --path`
- Define JSON output schema and exit codes (0: healthy, 1: unhealthy, 2: usage error)
- Add basic Bats tests for healthy/unhealthy path and JSON output  

### Sprint 2 – Multi-Path Monitoring & Environment Defaults ✅

**Goal:** Enable multiple path checks and support environment variable defaults.

**User Stories:**
- As a user, I can specify multiple filesystem paths to check via CLI or env variable.
- As a user, I receive an aggregate summary (JSON) of all paths checked.
- As a user, I can rerun checks idempotently and get consistent results.
- As a developer, I have Bats tests covering multi-path, partial failures, and env defaults.

**Acceptance Criteria:**
- JSON output includes one object per path plus an aggregate status.
- Exit codes: 0 (all healthy), 1 (one or more unhealthy), 2 (usage/config error).
- Multiple runs with same inputs produce consistent results.
- Bats tests cover: all healthy, some unhealthy, env vs CLI, aggregate status correctness.

### Sprint 3 – Disk Space & Inode Usage ✅
- Check free disk space and inode availability thresholds.
- Report warnings if usage exceeds limits.
- Example: Alert if `/var` partition exceeds 90% disk usage.

### Sprint 4 – Filesystem Type & Mount Status ✅
- Verify filesystem types (e.g., ext4, xfs) and mount status.
- Detect unmounted or remounted filesystems.
- Example: Ensure `/mnt/backup` is mounted as expected before backup jobs.

### Sprint 5 – LVM & RAID Awareness ✅
- Simulate LVM and RAID configurations.
- Detect degraded RAID arrays or LVM volume issues.
- Integrate with real LVM/MD tools if available.
- Example: Alert if RAID1 mirror is degraded or LVM volume is offline.
- **Note:** LVM tests are skipped if no `lvs.sample` fixture is present, per repo rules of no new files.

---

### Sprint 6 – Snapshot & Backup Validation ✅
- Check for presence and freshness of filesystem snapshots or backups.
- Validate backup mount points and access.
- Example: Verify daily snapshots exist and are accessible in `/snapshots`.
- Snapshot tests rely on ephemeral directories created in Docker and will fail if run outside the expected environment setup.

### Sprint 7 – Quotas & ACL Awareness ✅
- Detect user or group quotas on monitored paths.
- Validate ACLs to ensure correct permissions.
- Example: Alert if a user exceeds quota or ACLs restrict critical access.

### Sprint 8 – Performance Metrics & Historical Reporting ✅
- Collect IO stats, latency, and throughput over time.
- Generate historical reports and trends.
- Example: Report if disk IO latency exceeds thresholds over past 24h.

---

## Non-Goals

- Not intended as a full monitoring system or replacement for tools like Nagios or Prometheus.
- Does not perform deep filesystem repair or recovery.
- Focused on Linux filesystems; no Windows or macOS support planned.
- Not a comprehensive security audit tool; limited ACL awareness only.
