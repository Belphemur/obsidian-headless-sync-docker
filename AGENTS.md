# AGENTS.md — Project Guide for AI Agents

## Project Overview

**obsidian-headless-sync-docker** is a rootless Docker image that continuously syncs an [Obsidian](https://obsidian.md) vault using [obsidian-headless](https://github.com/obsidianmd/obsidian-headless), the official headless CLI for Obsidian Sync.

- **Repository:** <https://github.com/Belphemur/obsidian-headless-sync-docker>
- **Base image:** `node:lts-alpine`
- **Init system:** [s6-overlay v3](https://github.com/just-containers/s6-overlay)
- **Supported platforms:** `linux/amd64`, `linux/arm64`

## Key Design Decisions

1. **s6-overlay for process supervision** — The image uses s6-overlay v3 as its init system instead of a custom entrypoint script. This gives us proper signal handling, ordered service startup via dependency chains, and automatic restarts of the sync daemon.

2. **Configurable UID/GID** — `PUID`/`PGID` environment variables adjust the container's internal `obsidian` user at startup (via `usermod`/`groupmod`). All Obsidian commands then run as that user through `s6-setuidgid`.

3. **Persistent config volume** — The user's `~/.config` directory (`/home/obsidian/.config`) is a Docker volume so that login state and CLI configuration survive container restarts.

4. **Multi-arch support** — The Dockerfile handles both `amd64` (mapped to `x86_64`) and `arm64` (mapped to `aarch64`) for s6-overlay binary downloads using the Docker `TARGETARCH` build argument.

## Repository Structure

```
.
├── Dockerfile                  # Multi-arch rootless image with s6-overlay
├── compose.yml                 # Docker Compose configuration
├── .env.example                # Environment variable template
├── get-token.sh                # Interactive login helper (run with --entrypoint)
├── obsidian-sync.container     # Podman Quadlet systemd unit
├── rootfs/                     # Filesystem overlay copied into the image
│   └── etc/s6-overlay/
│       ├── s6-rc.d/            # s6-rc service definitions
│       │   ├── init-setup-user/
│       │   ├── init-check-auth/
│       │   ├── init-obsidian-login/
│       │   ├── init-setup-vault/
│       │   ├── svc-obsidian-sync/
│       │   └── user/contents.d/
│       └── scripts/            # Shell scripts referenced by oneshot services
├── docs/                       # Design documentation
│   └── s6-overlay-design.md    # Full s6-overlay architecture docs
├── AGENTS.md                   # This file
└── README.md                   # User-facing documentation
```

## s6-overlay Service Chain

Services are declared under `rootfs/etc/s6-overlay/s6-rc.d/` using the s6-rc v3 format:

| Service | Type | Depends On | Description |
|---|---|---|---|
| `init-setup-user` | oneshot | `base` | Adjusts obsidian user UID/GID to PUID/PGID |
| `init-check-auth` | oneshot | `init-setup-user` | Validates `OBSIDIAN_AUTH_TOKEN` is set |
| `init-obsidian-login` | oneshot | `init-check-auth` | Runs `ob login` as obsidian user |
| `init-setup-vault` | oneshot | `init-obsidian-login` | Runs `ob sync-setup` + config as obsidian user |
| `svc-obsidian-sync` | longrun | `init-setup-vault` | Runs `ob sync --continuous` as obsidian user |

All services are registered in `user/contents.d/` so s6-rc starts them at boot. Dependencies ensure correct ordering. If any oneshot fails, the container exits (`S6_BEHAVIOUR_IF_STAGE2_FAILS=2`).

## Build & Test

```bash
# Build for the current platform
docker build -t obsidian-headless-sync-docker .

# Build multi-arch (requires buildx)
docker buildx build --platform linux/amd64,linux/arm64 -t obsidian-headless-sync-docker .
```

There are no automated tests. Validation is done by building the image and running it with valid Obsidian credentials.

> **⚠️ Required before committing:** Always run `docker build -t obsidian-headless-sync-docker .` and verify the build succeeds before committing any changes to the Dockerfile, s6-overlay scripts, or any file copied into the image (`rootfs/`, `get-token.sh`). Do not commit if the build fails.

## CI/CD

- **`.github/workflows/ci.yml`** — Runs on every push to `main` and every PR. Builds the Docker image for both `linux/amd64` and `linux/arm64`, then runs a [Trivy](https://github.com/aquasecurity/trivy) vulnerability scan. SARIF results are uploaded to the GitHub Security tab automatically.
- **`.github/workflows/check-obsidian-version.yml`** — Daily cron job that checks the `obsidian-headless` npm package for new versions. If a new version is found, it creates a git tag and triggers a build.
- **`.github/workflows/docker-publish.yml`** — Reusable workflow that builds and pushes multi-arch images to `ghcr.io`. Runs on version tags and PRs (build-only for PRs).

## Conventions

- **Shell scripts** use `#!/command/with-contenv sh` shebang (s6-overlay helper that injects container environment variables).
- **Privilege dropping** — All `ob` commands run via `s6-setuidgid obsidian` to drop from root to the configured UID/GID.
- **Service definitions** follow the [s6-rc source definition format](https://skarnet.org/software/s6-rc/s6-rc-compile.html).
- **`type` files** end with a newline.
- **`up` files** contain a single command path referencing a script in `/etc/s6-overlay/scripts/`.
- **Dependency files** are empty files whose *name* is the dependency.
- **Image references** point to `ghcr.io/belphemur/obsidian-headless-sync-docker`.

## Environment Variables

All runtime configuration is via environment variables. See `README.md` and `.env.example` for the full list. Key variables:

- `OBSIDIAN_AUTH_TOKEN` (required) — Auth token from `ob login`
- `VAULT_NAME` (required on first run) — Remote vault name
- `VAULT_PASSWORD` — E2E encryption password (if enabled)
- `PUID` / `PGID` (default `1000`) — UID/GID for the container user
- `S6_BEHAVIOUR_IF_STAGE2_FAILS` — Set to `2` by default (stop on init failure)
