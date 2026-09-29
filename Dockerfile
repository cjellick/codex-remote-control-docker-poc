FROM ubuntu:24.04

ARG CODEX_VERSION=0.159.1
ARG DEBIAN_FRONTEND=noninteractive

RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        bubblewrap \
        ca-certificates \
        git \
        nodejs \
        npm \
    && npm install -g "@openai/codex@${CODEX_VERSION}" \
    && useradd --create-home --uid 1001 --shell /bin/bash codex \
    && mkdir -p /home/codex/.codex /home/codex/workspace \
    && chown -R codex:codex /home/codex \
    && rm -rf /var/lib/apt/lists/*

ENV HOME=/home/codex

USER codex
WORKDIR /home/codex/workspace

RUN git init --initial-branch=main

CMD ["sleep", "infinity"]
