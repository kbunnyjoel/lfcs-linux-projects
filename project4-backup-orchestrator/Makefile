# Project 4: Backup & Restore Orchestrator
# Make targets: build | shell | lint | test | docker-run

SHELL := /bin/bash
IMAGE ?= project4-backup-orchestrator
DOCKERFILE ?= Dockerfile

TMP_DIR := tmp
SRC_DIR := $(TMP_DIR)/src
DEST_DIR := $(TMP_DIR)/dest
OUT_DIR := outputs
LOG_DIR := logs

.PHONY: build shell lint test docker-run prep clean

build:
	@echo "==> Building $(IMAGE) from $(DOCKERFILE)"
	docker build -t $(IMAGE) -f $(DOCKERFILE) .

prep:
	@echo "==> Preparing local temp and output dirs ($(SRC_DIR), $(DEST_DIR), $(OUT_DIR), $(LOG_DIR))"
	@mkdir -p "$(SRC_DIR)" "$(DEST_DIR)" "$(OUT_DIR)" "$(LOG_DIR)"

shell: build
	@echo "==> Opening shell in container (mounted repo)"
	docker run --rm -it -v "$(PWD)":/app -w /app $(IMAGE) bash

lint: build
	@echo "==> Running ShellCheck"
	docker run --rm -v "$(PWD)":/app -w /app $(IMAGE) \
	  bash -lc 'shopt -s globstar nullglob; shellcheck src/**/*.sh || true'

test: build
	@echo "==> Running Bats tests"
	docker run --rm -v "$(PWD)":/app -w /app $(IMAGE) \
	  bash -lc 'mkdir -p "$(SRC_DIR)" "$(DEST_DIR)" "$(OUT_DIR)" "$(LOG_DIR)"; if compgen -G "tests/*.bats" > /dev/null; then bats -t tests/*.bats; else echo "No tests found"; fi'

docker-run: build
	@echo "==> Example run (placeholder until Sprint 1 code lands)"
	docker run --rm -v "$(PWD)":/app -w /app $(IMAGE) \
	  bash -lc 'set -e; mkdir -p "$(SRC_DIR)" "$(DEST_DIR)" "$(OUT_DIR)" "$(LOG_DIR)"; printf "sample\n" >"$(SRC_DIR)/example.txt"; src/backup.sh full --source "$(SRC_DIR)" --dest "$(DEST_DIR)" --format tar --compress gz --label demo --json || true; echo "Artifacts in $(DEST_DIR):"; ls -l "$(DEST_DIR)" || true'

clean:
	@echo "==> Cleaning local temp and output dirs"
	@rm -rf "$(TMP_DIR)" "$(OUT_DIR)" "$(LOG_DIR)"
