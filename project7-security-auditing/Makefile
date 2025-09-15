SHELL := /usr/bin/env bash
IMAGE ?= project7-sec
DEV_TAG := $(IMAGE)
SYSD_TAG := $(IMAGE):systemd

.PHONY: build build-dev build-systemd test lint fmt systemd-up scout

build: build-dev

build-dev:
	@docker build --target dev -t $(DEV_TAG) .

# Systemd runtime image (minimal, bootable with systemd)
build-systemd:
	@docker build --target runtime-systemd -t $(SYSD_TAG) .

test: build-dev
	@docker run --rm -v "$$PWD":/app -w /app $(DEV_TAG) bash -lc "chmod +x src/*.sh tests/helpers/* || true; bats -r tests"

lint: build-dev
	@docker run --rm -v "$$PWD":/app -w /app $(DEV_TAG) bash -lc "shellcheck src/*.sh || true"

fmt: build-dev
	@docker run --rm -v "$$PWD":/app -w /app $(DEV_TAG) bash -lc "shfmt -w src || true"

# Launch a systemd-enabled container for the service/timer demo
systemd-up: build-systemd
	-@docker rm -f secd 2>/dev/null || true
	@docker run --name secd --privileged --cgroupns=host -v /sys/fs/cgroup:/sys/fs/cgroup:rw --tmpfs /run --tmpfs /run/lock -v "$$PWD":/app -w /app $(SYSD_TAG)

# Optional: summarize image vulnerabilities (requires Docker Scout locally)
scout: build-dev build-systemd
	@docker scout quickview $(DEV_TAG) || echo "Docker Scout not available; skipping dev"
	@docker scout quickview $(SYSD_TAG) || echo "Docker Scout not available; skipping systemd"
