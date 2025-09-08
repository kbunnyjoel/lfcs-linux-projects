

# Project 4: Backup & Restore Orchestrator
# Base image with tools required for building, linting, and testing

FROM ubuntu:24.04

ENV DEBIAN_FRONTEND=noninteractive

# Install required packages
RUN apt-get update && apt-get install -y --no-install-recommends \
    bash coreutils findutils grep sed gawk \
    tar gzip zstd rsync openssh-client \
    jq \
    shellcheck bats \
  && rm -rf /var/lib/apt/lists/*

# Create working directory
WORKDIR /app

# Default command (overridden by Makefile targets)
CMD ["bash"]
