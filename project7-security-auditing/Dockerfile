# Dev image for Project 7 (Security & Auditing)
FROM ubuntu:22.04 AS dev

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update && apt-get install -y --no-install-recommends \
    bash coreutils jq make ca-certificates \
    bats shellcheck shfmt \
  && rm -rf /var/lib/apt/lists/*

WORKDIR /app
COPY . /app

# Run the test suite by default (override with docker run ... "bash -lc '...'")
CMD ["bash","-lc","bats -r tests"]

# --------------------------------------
# Target: runtime-systemd (systemd base)
# --------------------------------------
# This image is for systemd timer/service testing of sec-check.
FROM jrei/systemd-ubuntu:22.04 AS runtime-systemd

ENV DEBIAN_FRONTEND=noninteractive
ENV container=docker

RUN apt-get update && apt-get install -y --no-install-recommends \
    bash coreutils jq \
  && rm -rf /var/lib/apt/lists/*

# Helpful: avoid noisy/getty units inside Docker
RUN systemctl mask \
      getty@.service \
      console-getty.service \
      systemd-logind.service || true

WORKDIR /app
COPY . /app

# Allow cgroups when running with --privileged and mounting /sys/fs/cgroup
VOLUME ["/sys/fs/cgroup"]

# Default entrypoint for systemd containers
CMD ["/sbin/init"]
