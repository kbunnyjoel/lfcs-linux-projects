# Makefile
IMAGE ?= lfcs-monitor
WORKSPACE := $(shell pwd)
VOLUME := -v "$(WORKSPACE)":/app
WORKDIR := /app/setup
ENV ?= dev

# Resolve env file on the HOST (Docker reads it from the host filesystem)
# Note: we resolve inside the recipe to preserve spaces-in-paths
ENV_CANDIDATES := $(WORKSPACE)/env/$(ENV).env $(WORKSPACE)/env/$(ENV)

.PHONY: docker-build docker-run docker-shell docker-clean pretty-json metrics-server

docker-build:
	@echo "==> Building $(IMAGE) from Dockerfile"
	docker build --no-cache -t $(IMAGE) -f Dockerfile .

docker-run: docker-build
	@echo "==> Running install.sh $(ENV) inside container"
	@ENV_FILE=$$( if [ -f "$(WORKSPACE)/env/$(ENV).env" ]; then echo "$(WORKSPACE)/env/$(ENV).env"; \
	              elif [ -f "$(WORKSPACE)/env/$(ENV)" ]; then echo "$(WORKSPACE)/env/$(ENV)"; \
	              fi ); \
	 test -n "$$ENV_FILE" || (echo "ENV file not found. Tried: $(ENV_CANDIDATES)" >&2; exit 2); \
	 docker run --rm -it \
	   $(VOLUME) \
	   -w $(WORKDIR) \
	   --env-file "$$ENV_FILE" \
	   $(IMAGE) \
	   bash -lc "./install.sh $(ENV)"

metrics-server: docker-build
	@echo "==> Starting metrics server on :9100 (ENV=$(ENV), IMPL=$(SERVER_IMPL))"
	@ENV_FILE=$$( if [ -f "$(WORKSPACE)/env/$(ENV).env" ]; then echo "$(WORKSPACE)/env/$(ENV).env"; \
	              elif [ -f "$(WORKSPACE)/env/$(ENV)" ]; then echo "$(WORKSPACE)/env/$(ENV)"; \
	              fi ); \
	 test -n "$$ENV_FILE" || (echo "ENV file not found. Tried: $(ENV_CANDIDATES)" >&2; exit 2); \
	 if [ "$(SERVER_IMPL)" = "nc" ]; then \
	   docker run --rm -it \
	     $(VOLUME) \
	     -w $(WORKDIR) \
	     -p 9100:9100 \
	     --env-file "$$ENV_FILE" \
	     $(IMAGE) \
	     bash -lc 'apt-get update >/dev/null && apt-get install -y --no-install-recommends netcat-openbsd >/dev/null && \
	       while true; do \
	         { \
	           printf "HTTP/1.1 200 OK\\r\\n"; \
	           printf "Content-Type: text/plain; version=0.0.4\\r\\n\\r\\n"; \
	           cat ../outputs/latest.prom || true; \
	           printf "\\r\\n"; \
	         } | nc -l -p 9100 -q 1; \
	       done'; \
	 else \
	   docker run --rm -it \
	     $(VOLUME) \
	     -w /app \
	     -p 9100:9100 \
	     -e MON_ENV="$(ENV)" \
	     --env-file "$$ENV_FILE" \
	     $(IMAGE) \
	     bash -lc 'apt-get update >/dev/null && apt-get install -y --no-install-recommends python3 >/dev/null && python3 serve_metrics.py'; \
	 fi

docker-shell: docker-build
	@echo "==> Opening interactive shell in container at $(WORKDIR)"
	docker run --rm -it \
	  $(VOLUME) \
	  -w $(WORKDIR) \
	  $(IMAGE) \
	  bash

docker-clean:
	@echo "==> Removing image $(IMAGE) if present"
	-@docker rmi $(IMAGE)

pretty-json:
	@echo "==> Pretty-printing outputs/latest.json"
	@docker run --rm -v "$(WORKSPACE)":/app python:3.12-alpine \
	  sh -lc 'python -m json.tool < /app/outputs/latest.json'
