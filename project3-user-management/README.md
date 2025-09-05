# Project 3 — User & Access Management Toolkit

Goal: a safe, idempotent, testable CLI for Linux user/group management, built with strict Bash practices and end-to-end tests.

## Features (Sprint 1)
- Containerized development (Ubuntu)
- CLI `userctl.sh`:
  - `list` — list local users (human accounts by default)
  - `exists <username>` — exit 0 if present, 1 otherwise
  - `add <username> [-g grp1,grp2] [-s /bin/bash] [--system]` — idempotent
- Tests with Bats (`make test`)
- Lint with ShellCheck (`make lint`)

> Safety: all commands run in a **container**; your host system isn’t modified.

## Quick start
```bash
make test         # build image and run tests
make lint         # shellcheck all scripts
make shell        # debug shell inside the dev container

# manual usage in the container
docker run --rm -it -v "$PWD":/app -w /app project3-um \
  bash -lc 'src/userctl.sh add alice -g developers -s /bin/bash && src/userctl.sh list'
