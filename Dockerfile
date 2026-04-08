# ============================================================
# BACKUP DOCKERFILE FOR MTPROXY (Telemt-Plus)
# ============================================================
# This file is a frozen backup of the official Telemt engine.
# It is NOT used by default. The project currently pulls the
# official pre-built image for maximum speed and compatibility.
# 
# Source: https://github.com/telemt/telemt
# Version: 3.3.38 (Stable)
# ============================================================

# syntax=docker/dockerfile:1

ARG TELEMT_REPOSITORY=telemt/telemt
ARG TELEMT_VERSION=3.3.38

# Stage 1: Download and verify binary
FROM debian:12-slim AS minimal

ARG TARGETARCH
ARG TELEMT_REPOSITORY
ARG TELEMT_VERSION

RUN set -eux; \
    apt-get update; \
    apt-get install -y --no-install-recommends \
        binutils \
        ca-certificates \
        curl \
        tar; \
    rm -rf /var/lib/apt/lists/*

RUN set -eux; \
    case "${TARGETARCH}" in \
        amd64) ASSET="telemt-x86_64-linux-musl.tar.gz" ;; \
        arm64) ASSET="telemt-aarch64-linux-musl.tar.gz" ;; \
        *) echo "Unsupported TARGETARCH: ${TARGETARCH}" >&2; exit 1 ;; \
    esac; \
    VERSION="${TELEMT_VERSION#refs/tags/}"; \
    BASE_URL="https://github.com/${TELEMT_REPOSITORY}/releases/download/${VERSION}"; \
    curl -fL --retry 5 -o "/tmp/${ASSET}" "${BASE_URL}/${ASSET}"; \
    curl -fL --retry 5 -o "/tmp/${ASSET}.sha256" "${BASE_URL}/${ASSET}.sha256"; \
    cd /tmp; \
    sha256sum -c "${ASSET}.sha256"; \
    tar -xzf "${ASSET}" -C /tmp; \
    install -m 0755 /tmp/telemt /telemt; \
    rm -f "/tmp/${ASSET}" "/tmp/${ASSET}.sha256" /tmp/telemt

# Stage 2: Final minimal image
FROM gcr.io/distroless/static-debian12 AS prod

WORKDIR /app
COPY --from=minimal /telemt /app/telemt

# NOTE: config.toml is mounted at runtime via RAM-disk (/dev/shm)
# as defined in docker-compose.yml. We don't bake it into the image.

USER nonroot:nonroot
EXPOSE 443 9091
ENTRYPOINT ["/app/telemt"]
CMD ["/run/telemt/config.toml"]
