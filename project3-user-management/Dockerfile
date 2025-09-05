FROM ubuntu:24.04

ENV DEBIAN_FRONTEND=noninteractive
RUN apt-get update && apt-get install -y --no-install-recommends \
    bash coreutils findutils grep sed gawk util-linux sudo \
    passwd login adduser vim tini ca-certificates \
    shellcheck bats \
  && rm -rf /var/lib/apt/lists/*

WORKDIR /app
ENTRYPOINT ["/usr/bin/tini","--"]
CMD ["bash"]
