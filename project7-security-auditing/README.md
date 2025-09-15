# Project 7 – Security & Auditing

Bash utilities and tests to validate baseline security hardening on Linux systems. Sprint 1 focuses on simulating and validating:
- Firewall rules present (firewalld or iptables/nft)
- SELinux/AppArmor status and mode
- auditd rules loaded and events captured
- Auth monitoring for failed logins
- Optional file integrity scan (aide-like mock)

---

## Repo layout

```
project7-security-auditing/
├─ env/
│  ├─ dev.env
│  └─ prod.env
├─ src/
│  ├─ sec.sh            # main CLI
│  ├─ firewall.sh       # helpers for firewall detection
│  ├─ selinux.sh        # helpers for SELinux/AppArmor
│  ├─ auditd.sh         # helpers for audit rules/events
│  └─ auth.sh           # helpers for login failure checks
├─ tests/
│  ├─ helpers/
│  │  ├─ firewallctl    # mock firewalld/iptables
│  │  ├─ getenforce     # mock selinux status
│  │  ├─ aa-status      # mock apparmor
│  │  ├─ auditctl       # mock audit rules
│  │  └─ lastb          # mock failed logins
│  ├─ fixtures/
│  │  └─ audit.rules.sample
│  └─ test_sec_basic.bats
├─ Dockerfile
├─ Makefile
└─ README.md
```

---

## Sprint 1 scope

- CLI: `src/sec.sh check` with options:
  - `--json`               : print JSON per check and summary
  - `--firewall required`  : require firewall present/active
  - `--selinux enforcing|permissive|disabled` : required SELinux mode (if SELinux present)
  - `--apparmor required`  : require AppArmor present/enabled
  - `--audit rules FILE`   : require audit rules include key patterns from FILE
  - `--auth max-failed N`  : maximum failed logins in last 24h
  - `--aide required`      : require successful integrity scan (mocked)
- Exit codes: `0` all healthy, `1` any non‑compliance, `2` usage error.
- Tests use mocks and do not require host privileges.

---

## Usage

Local (host, simulated):
```bash
# JSON summary with firewall+audit checks
src/sec.sh check --json --firewall required --audit rules tests/fixtures/audit.rules.sample
```

Docker (dev image):
```bash
make test
```

---

## JSON format
Example summary:
```json
{
  "timestamp": "2025-01-01T00:00:00Z",
  "summary": true,
  "overall": "up",
  "healthy": ["firewall","selinux","audit","auth"],
  "unhealthy": []
}
```

Per-check lines include `component`, `ok`, and component‑specific fields.

---

## Notes
- Mocks in `tests/helpers/` simulate system commands.
- `env/dev.env` keeps relaxed defaults; `env/prod.env` is stricter.
- In later sprints we can add real‑mode probes guarded behind env flags.

---

## Scheduling (systemd or cron)

Systemd (host or a systemd-enabled container):
- Unit files: `deploy/systemd/sec-check.service`, `deploy/systemd/sec-check.timer`
- Configure `/etc/project7/env` with desired flags (e.g., `SEC_ARGS="--json --firewall required ..."`).
- Enable timer: `systemctl enable --now sec-check.timer`

Cron example (host):
- `deploy/cron.example` shows how to run `sec.sh check` every 10 minutes, sourcing `/etc/project7/env`.

