# Project 5 – Service Watchdog (Sprint 1)
# Minimal image to run the watchdog script and Bats tests

FROM ubuntu:24.04

# Core utilities + jq (for JSON), procps (for pgrep), bats (tests), tini (init)
RUN apt-get update && apt-get install -y --no-install-recommends \
    bash coreutils findutils grep sed gawk procps jq \
    ca-certificates curl tini bats msmtp msmtp-mta \
  && rm -rf /var/lib/apt/lists/*

RUN mkdir -p /var/log/msmtp && chmod 755 /var/log/msmtp

# Workdir inside the container
WORKDIR /app

# Ensure standard runtime directories exist (used by watch.sh/notify.sh and tests)
RUN mkdir -p /app/logs /app/outputs

# Copy code and tests (keep layers simple for Sprint 1)
COPY src/ src/
COPY tests/ tests/
# Optional: environment presets if present

COPY env/ env/

RUN if [ -f env/dev.env ]; then ln -sf env/dev.env env/dev; fi && if [ -f env/prod.env ]; then ln -sf env/prod.env env/prod; fi

# Add src and src/lib to PATH so tests can resolve notify.sh
ENV PATH="/app/src:/app/src/lib:${PATH}"

# Ensure executables
RUN chmod +x src/watch.sh src/lib/notify.sh || true

# Add a stable CLI alias for tests and humans
RUN ln -sf /app/src/lib/notify.sh /usr/local/bin/notify.sh

# Default to an interactive shell; CI will override with test commands
CMD ["bash"]
