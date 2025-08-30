# Dockerfile
FROM ubuntu:24.04

ENV DEBIAN_FRONTEND=noninteractive
RUN apt-get update && apt-get install -y --no-install-recommends \
    bash ca-certificates coreutils procps util-linux iproute2 \
    net-tools sysstat gawk sed grep bc \
  && rm -rf /var/lib/apt/lists/*

WORKDIR /app
