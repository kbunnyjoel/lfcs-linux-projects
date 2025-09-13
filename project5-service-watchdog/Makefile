

IMAGE := project5-service-watchdog
WORKDIR := /app
BATS ?= tests/*.bats

# Defaults for notification helper
ENV ?= dev
SUBJECT ?= Watchdog OK
BODY ?= All healthy
LEVEL ?= info
TO ?=
FROM ?=

# Default demo health scripts (used by watch targets)
HEALTH ?= tests/fixtures/health.sh
RESTART ?= tests/fixtures/restart.sh

.PHONY: help build test sh fmt clean notify notify-dev notify-prod watch watch-once test-watch test-notify watch-backoff

help:
	@echo "Targets:"
	@echo "  build     Build Docker image ($(IMAGE))"
	@echo "  test      Run Bats tests inside container"
	@echo "  sh        Start an interactive shell in the container"
	@echo "  fmt       Run shellcheck (lint) inside container"
	@echo "  clean     Remove temp outputs/logs (local); no docker prune"
	@echo "  notify    Send a test notification (uses env vars: ENV, SUBJECT, BODY, LEVEL, TO, FROM)"
	@echo "  notify-dev  Shortcut for notify with ENV=dev"
	@echo "  notify-prod Shortcut for notify with ENV=prod"
	@echo "  watch       Run a demo health check (uses fixtures/health.sh & fixtures/restart.sh)"
	@echo "  watch-once  Run a one-shot unhealthy check (no restart), prints exit code"
	@echo "  test-watch Run only watch-related bats tests (tests/test_watch_*.bats)"
	@echo "  test-notify Run only notify/schedule bats tests (tests/test_schedule.bats)"
	@echo "  watch-backoff  Demo check with backoff/jitter flags"
	@echo ""
	@echo "Variables:"
	@echo "  BATS     Glob of tests to run (default: tests/*.bats). e.g., 'make test BATS=tests/test_watch_basic.bats'"
	@echo "  ENV/SUBJECT/BODY/LEVEL/TO/FROM used by 'make notify'"

build:
	docker build -t $(IMAGE) -f Dockerfile .

# Run tests in a clean container. We mkdir common temp dirs so tests don't fail on missing paths.
test: build
	docker run --rm -v "$$(pwd)":$(WORKDIR) -w $(WORKDIR) $(IMAGE) \
		bash -lc 'mkdir -p "tmp/src" "tmp/dest" "outputs" "logs"; if compgen -G "$(BATS)" > /dev/null; then bats -t $(BATS); else echo "No tests found"; fi'

# Interactive shell for debugging
sh: build
	docker run --rm -it -v "$$(pwd)":$(WORKDIR) -w $(WORKDIR) $(IMAGE) bash

# Lint all shell scripts with shellcheck inside the image
fmt: build
	docker run --rm -v "$$(pwd)":$(WORKDIR) -w $(WORKDIR) $(IMAGE) \
		bash -lc 'if command -v shellcheck >/dev/null 2>&1; then shellcheck -x src/*.sh src/lib/*.sh 2>/dev/null || true; else echo "shellcheck not installed in image"; fi'

# Send a notification via src/lib/notify.sh (email/log). Override ENV, SUBJECT, BODY, LEVEL, TO, FROM.
notify: build
	docker run --rm \
		-e ENV="$(ENV)" -e SUBJECT="$(SUBJECT)" -e BODY="$(BODY)" -e LEVEL="$(LEVEL)" -e TO="$(TO)" -e FROM="$(FROM)" \
		-v "$$(pwd)":$(WORKDIR) -w $(WORKDIR) $(IMAGE) \
		bash -lc 'src/lib/notify.sh send ${TO:+--to "$$TO"} ${FROM:+--from "$$FROM"} ${ENV:+--env "$$ENV"} --subject "$$SUBJECT" --body "$$BODY" --level "$$LEVEL" --json'

notify-dev: 
	$(MAKE) notify ENV=dev

notify-prod: 
	$(MAKE) notify ENV=prod

# Run only watch-related bats tests
test-watch: build
	docker run --rm -v "$$(pwd)":$(WORKDIR) -w $(WORKDIR) $(IMAGE) \
		bash -lc 'mkdir -p "tmp/src" "tmp/dest" "outputs" "logs"; if compgen -G "tests/test_watch_*.bats" > /dev/null; then bats -t tests/test_watch_*.bats; else echo "No watch tests found"; fi'

# Run only notify/schedule bats tests
test-notify: build
	docker run --rm -v "$$(pwd)":$(WORKDIR) -w $(WORKDIR) $(IMAGE) \
		bash -lc 'mkdir -p "tmp/src" "tmp/dest" "outputs" "logs"; if [ -f tests/test_schedule.bats ]; then bats -t tests/test_schedule.bats; else echo "No notify tests found"; fi'

# Demo health check with repository fixtures (quiet JSON to stdout)
watch: build
	docker run --rm -v "$$(pwd)":$(WORKDIR) -w $(WORKDIR) $(IMAGE) \
		bash -lc 'src/watch.sh check --health-cmd $(HEALTH) --start-cmd $(RESTART) --max-retries 1 --json --quiet'

# One-shot health check (no restart), prints exit code even when JSON is emitted
watch-once: build
	docker run --rm -v "$$(pwd)":$(WORKDIR) -w $(WORKDIR) $(IMAGE) \
		bash -lc 'set +e; src/watch.sh check --health-cmd tests/fixtures/health.sh --once --json --quiet; rc=$$?; echo "exit=$$rc"; exit $$rc'

# Demo check with backoff/jitter flags
watch-backoff: build
	docker run --rm -v "$$(pwd)":$(WORKDIR) -w $(WORKDIR) $(IMAGE) \
		bash -lc 'src/watch.sh check --health-cmd $(HEALTH) --start-cmd $(RESTART) --max-retries 3 --retry-interval 1 --backoff exp --retry-max-interval 8 --jitter 0.2 --json --quiet'

# Local cleanup only
clean:
	rm -rf tmp outputs logs
