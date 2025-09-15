#
# -----------------------------
# Target: dev (used by make test)
# -----------------------------
FROM ubuntu:22.04 AS dev

ENV DEBIAN_FRONTEND=noninteractive
ENV container=docker

# Core tooling for building & testing
RUN apt-get update && apt-get install -y --no-install-recommends \
    bash coreutils jq make git ca-certificates \
    bats shellcheck shfmt \
    e2fsprogs util-linux mount xfsprogs \
  && rm -rf /var/lib/apt/lists/*

WORKDIR /app
COPY . /app

# Run the test suite by default (override with docker run ... "bash -lc '...'")
CMD ["bash","-lc","bats -r tests"]


# -----------------------------
# Target: test (compat alias)
# -----------------------------
FROM dev AS test


# --------------------------------------
# Target: runtime-systemd (systemd base)
# --------------------------------------
# This image is only for Sprint 8 systemd timer/service testing.
FROM jrei/systemd-ubuntu:22.04 AS runtime-systemd

ENV DEBIAN_FRONTEND=noninteractive
ENV container=docker

# Keep it minimal — we only need what's required to run fs.sh and a timer
RUN apt-get update && apt-get install -y --no-install-recommends \
    bash coreutils jq \
  && rm -rf /var/lib/apt/lists/*

# Helpful: avoid noisy/getty units inside Docker
# (they’re not required and can slow/complicate container boot)
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
