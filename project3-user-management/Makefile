## `project3-user-management/Makefile`
IMAGE ?= project3-user-management
WORKDIR := /app

.PHONY: build test lint shell

build:
	@docker build --no-cache -t $(IMAGE) -f Dockerfile .

test: build
	@docker run --rm -it -v "$$(pwd)":$(WORKDIR) -w $(WORKDIR) $(IMAGE) \
	  bash -lc 'bats tests'

lint: build
	@docker run --rm -it -v "$$(pwd)":$(WORKDIR) -w $(WORKDIR) $(IMAGE) \
	  bash -lc 'shellcheck -x src/userctl.sh src/lib/common.sh'

shell: build
	@docker run --rm -it -v "$$(pwd)":$(WORKDIR) -w $(WORKDIR) $(IMAGE) bash
