FROM node:lts-alpine

ARG S6_OVERLAY_VERSION=3.2.2.0
ARG TARGETARCH

# ---------------------------------------------------------------------------
# Install s6-overlay (static binaries – works on musl and glibc)
# ---------------------------------------------------------------------------
RUN apk add --no-cache --virtual .s6-deps xz \
    && S6_ARCH="$(case "${TARGETARCH}" in \
         amd64) echo x86_64;; \
         arm64) echo aarch64;; \
         *) echo "Unsupported architecture: ${TARGETARCH}" >&2; exit 1;; \
       esac)" \
    && wget -qO /tmp/s6-noarch.tar.xz \
       "https://github.com/just-containers/s6-overlay/releases/download/v${S6_OVERLAY_VERSION}/s6-overlay-noarch.tar.xz" \
    && wget -qO /tmp/s6-arch.tar.xz \
       "https://github.com/just-containers/s6-overlay/releases/download/v${S6_OVERLAY_VERSION}/s6-overlay-${S6_ARCH}.tar.xz" \
    && tar -C / -Jxpf /tmp/s6-noarch.tar.xz \
    && tar -C / -Jxpf /tmp/s6-arch.tar.xz \
    && rm -f /tmp/s6-*.tar.xz \
    && apk del .s6-deps

# ---------------------------------------------------------------------------
# Install obsidian-headless CLI (requires Node 22+)
# ---------------------------------------------------------------------------
RUN npm install -g obsidian-headless

# ---------------------------------------------------------------------------
# Runtime deps: shadow provides usermod/groupmod for PUID/PGID support
# ---------------------------------------------------------------------------
RUN apk add --no-cache shadow

# ---------------------------------------------------------------------------
# Create default non-root user (UID/GID adjustable at runtime via PUID/PGID)
# node:lts-alpine ships a 'node' user/group at UID/GID 1000 — remove it first
# ---------------------------------------------------------------------------
RUN deluser --remove-home node || true; \
    delgroup node || true; \
    addgroup -g 1000 obsidian \
    && adduser -u 1000 -G obsidian -h /home/obsidian -s /bin/sh -D obsidian \
    && mkdir -p /vault /home/obsidian/.config

# ---------------------------------------------------------------------------
# Copy s6-overlay service definitions, init scripts, and helper
# ---------------------------------------------------------------------------
COPY rootfs/ /
COPY get-token.sh /usr/local/bin/get-token
RUN chmod +x /usr/local/bin/get-token \
    && find /etc/s6-overlay/scripts -type f -exec chmod +x {} + \
    && chmod +x /etc/s6-overlay/s6-rc.d/svc-obsidian-sync/run

# ---------------------------------------------------------------------------
# Volumes: vault data + user config persistence (login state, etc.)
# ---------------------------------------------------------------------------
VOLUME ["/vault", "/home/obsidian/.config"]

# s6-overlay: stop container if any init oneshot fails
ENV S6_BEHAVIOUR_IF_STAGE2_FAILS=2
ENV HOME=/home/obsidian

ENTRYPOINT ["/init"]
