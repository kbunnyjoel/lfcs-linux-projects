SHELL := /usr/bin/env bash
IMAGE ?= project6-fs
DEV_TAG := $(IMAGE)
SYSD_TAG := $(IMAGE):systemd

.PHONY: build build-dev build-systemd test lint fmt fs-sim fs-real systemd-up

# Default build builds the dev/test image (has bats, shellcheck, etc.)
build: build-dev

# Dev/Test image (contains bats & tooling)
build-dev:
	@docker build --target dev -t $(DEV_TAG) .

# Systemd runtime image (minimal, bootable with systemd)
build-systemd:
	@docker build --target runtime-systemd -t $(SYSD_TAG) .

test: build-dev
	@docker run --rm -v "$$PWD":/app -w /app $(DEV_TAG) bash -lc "FS_ENV_FILE=/dev/null FS_DEBUG= bats -r tests"

lint: build-dev
	@docker run --rm -v "$$PWD":/app -w /app $(DEV_TAG) bash -lc "shellcheck src/*.sh || true"

fmt: build-dev
	@docker run --rm -v "$$PWD":/app -w /app $(DEV_TAG) bash -lc "shfmt -w src || true"

# Alias for current sprints (simulate mode)
fs-sim: test

# Placeholder for later sprints; runs only the real-mode tests when we add them
fs-real: build-dev
	@docker run --rm -v "$$PWD":/app -w /app -e FS_REAL=1 -e FS_MODE=real --privileged $(DEV_TAG) bash -lc "bats -r tests/test_fs_real.bats || true"

# Launch a systemd-enabled container for the service/timer demo
systemd-up: build-systemd
	-@docker rm -f fsd 2>/dev/null || true
	@docker run --name fsd --privileged --cgroupns=host -v /sys/fs/cgroup:/sys/fs/cgroup:rw --tmpfs /run --tmpfs /run/lock -v "$$PWD":/app -w /app $(SYSD_TAG)
