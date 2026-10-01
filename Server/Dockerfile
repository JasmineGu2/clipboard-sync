# syntax=docker/dockerfile:1
# Build from the REPO ROOT (the relay depends on the root package by path):
#   docker build -f Server/Dockerfile -t clip-relay .
# BuildKit reads Server/Dockerfile.dockerignore for this build.

# ---- Build ----
# 6.2+ is required: current Hummingbird 2.x, swift-log and swift-configuration use tools 6.2.
FROM swift:6.3-jammy AS build
RUN apt-get update \
    && apt-get install -y --no-install-recommends libsqlite3-dev \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /src
COPY . .
RUN swift build -c release --package-path Server --product ClipRelay --static-swift-stdlib \
        --scratch-path /build \
    && install -D "$(swift build -c release --package-path Server --scratch-path /build --show-bin-path)/ClipRelay" \
        /staging/ClipRelay

# ---- Run ----
FROM ubuntu:jammy
RUN apt-get update \
    && apt-get install -y --no-install-recommends libsqlite3-0 ca-certificates \
    && rm -rf /var/lib/apt/lists/* \
    && useradd --system --home-dir /data --create-home --uid 10001 relay

COPY --from=build /staging/ClipRelay /usr/local/bin/ClipRelay
USER relay
VOLUME /data
EXPOSE 8787

# Inside the container the relay must listen on 0.0.0.0 so the published port reaches it.
# Publish ONLY on the host's Tailscale IP:  docker run -p 100.x.y.z:8787:8787 ...
ENTRYPOINT ["/usr/local/bin/ClipRelay"]
CMD ["--host", "0.0.0.0", "--port", "8787", "--db", "/data/relay.sqlite3"]
