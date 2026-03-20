# s6-overlay Design

This document explains the s6-overlay architecture used in the obsidian-headless-sync-docker image, including design decisions, service structure, and how the components interact.

## Why s6-overlay?

The previous architecture used a monolithic `entrypoint.sh` script that handled auth validation, vault setup, privilege dropping (via `su-exec`), and launching the sync process all in one file. This had several drawbacks:

- **No process supervision** — if `ob sync` crashed, the entire container exited
- **Runtime privilege management** — required `PUID`/`PGID` env vars and `chown` at every start
- **Poor signal handling** — shell scripts don't always forward signals correctly to child processes
- **No ordered startup** — all logic was sequential in a single script with no dependency management

[s6-overlay v3](https://github.com/just-containers/s6-overlay) solves all of these:

| Feature | Old (entrypoint.sh) | New (s6-overlay) |
|---|---|---|
| Process supervision | None (container exits on crash) | s6 restarts the sync daemon automatically |
| Signal handling | Shell `exec` (fragile) | Proper PID 1 init with signal forwarding |
| Startup ordering | Sequential in one script | Dependency-based s6-rc service chain |
| Privilege model | Runtime `chown` + `su-exec` | Rootless image, no runtime privilege ops |
| Modularity | Single script | Separate service definitions |

## Rootless Design

The image runs entirely as the `obsidian` user (UID 1000). There is no runtime `chown`, no `PUID`/`PGID` environment variables, and no privilege dropping.

### Build-Time Setup

During the Docker build:

1. s6-overlay is extracted to `/` (as root, standard for s6-overlay installation)
2. The `obsidian` user and group are created (UID/GID 1000)
3. `/vault` and `/home/obsidian/.config` directories are created with correct ownership
4. `/run` is made writable by the `obsidian` user (s6-overlay needs this for runtime state)
5. `USER obsidian` is set — all runtime operations execute as this user

### Runtime

- s6-overlay's `/init` runs as UID 1000
- All s6-rc services (oneshots and longruns) run as the same user
- Scripts use `#!/command/with-contenv sh` to access container environment variables
- No capability escalation, no setuid binaries

### Volume Permissions

Two volumes are exposed:

| Volume | Path | Purpose |
|---|---|---|
| Vault data | `/vault` | Obsidian vault files (bind-mount your local vault) |
| User config | `/home/obsidian/.config` | Persistent CLI config (login state, sync metadata) |

The host directories must be writable by UID 1000. With rootless Docker/Podman, container UID 1000 maps to your host user automatically.

## Service Architecture

### s6-rc Service Chain

```
                    ┌──────────────────┐
                    │       base       │  (s6-overlay built-in)
                    └────────┬─────────┘
                             │
                    ┌────────▼─────────┐
                    │  init-check-auth │  oneshot: validate OBSIDIAN_AUTH_TOKEN
                    └────────┬─────────┘
                             │
                    ┌────────▼──────────────┐
                    │  init-obsidian-login  │  oneshot: run ob login
                    └────────┬──────────────┘
                             │
                    ┌────────▼──────────────┐
                    │   init-setup-vault    │  oneshot: ob sync-setup + config
                    └────────┬──────────────┘
                             │
                    ┌────────▼──────────────┐
                    │  svc-obsidian-sync    │  longrun: ob sync --continuous
                    └───────────────────────┘
```

Each service depends on the one above it. s6-rc resolves the dependency graph and executes them in order. If any oneshot exits non-zero, the container stops immediately (`S6_BEHAVIOUR_IF_STAGE2_FAILS=2`).

### Service Types

**Oneshot services** run once during initialization and exit. They are defined with:

- `type` — contains `oneshot`
- `up` — contains the path to the script to execute
- `dependencies.d/` — empty files named after dependencies

**Longrun services** are supervised daemons. They are defined with:

- `type` — contains `longrun`
- `run` — the executable script (must `exec` the final process)
- `dependencies.d/` — empty files named after dependencies

All services are registered in `user/contents.d/` (empty files named after the service) so that s6-rc includes them in the boot sequence.

### File Layout

```
rootfs/etc/s6-overlay/
├── s6-rc.d/
│   ├── init-check-auth/
│   │   ├── type                    → "oneshot"
│   │   ├── up                      → "/etc/s6-overlay/scripts/init-check-auth"
│   │   └── dependencies.d/
│   │       └── base                → (empty file)
│   ├── init-obsidian-login/
│   │   ├── type                    → "oneshot"
│   │   ├── up                      → "/etc/s6-overlay/scripts/init-obsidian-login"
│   │   └── dependencies.d/
│   │       └── init-check-auth     → (empty file)
│   ├── init-setup-vault/
│   │   ├── type                    → "oneshot"
│   │   ├── up                      → "/etc/s6-overlay/scripts/init-setup-vault"
│   │   └── dependencies.d/
│   │       └── init-obsidian-login → (empty file)
│   ├── svc-obsidian-sync/
│   │   ├── type                    → "longrun"
│   │   ├── run                     → executable script (with-contenv + exec ob sync)
│   │   └── dependencies.d/
│   │       └── init-setup-vault    → (empty file)
│   └── user/
│       └── contents.d/
│           ├── init-check-auth     → (empty file)
│           ├── init-obsidian-login → (empty file)
│           ├── init-setup-vault    → (empty file)
│           └── svc-obsidian-sync   → (empty file)
└── scripts/
    ├── init-check-auth             → validates OBSIDIAN_AUTH_TOKEN
    ├── init-obsidian-login         → runs ob login
    └── init-setup-vault            → runs ob sync-setup + optional config
```

## Multi-Architecture Support

The image supports `linux/amd64` and `linux/arm64`. s6-overlay uses gcc-style architecture names while Docker uses its own:

| Docker `TARGETARCH` | s6-overlay `${arch}` |
|---|---|
| `amd64` | `x86_64` |
| `arm64` | `aarch64` |

The Dockerfile maps between these at build time:

```dockerfile
ARG TARGETARCH
RUN S6_ARCH="$(case "${TARGETARCH}" in \
      amd64) echo x86_64;; \
      arm64) echo aarch64;; \
    esac)" \
    && wget ... s6-overlay-${S6_ARCH}.tar.xz ...
```

The CI pipeline builds both architectures using `docker buildx` with QEMU emulation:

```yaml
platforms: linux/amd64,linux/arm64
```

## s6-overlay Environment Variables

| Variable | Default | Effect |
|---|---|---|
| `S6_BEHAVIOUR_IF_STAGE2_FAILS` | `2` | Stop container if any init service fails |
| `S6_VERBOSITY` | `2` (default) | Controls s6-rc log verbosity (0=errors only, 5=trace) |
| `S6_CMD_WAIT_FOR_SERVICES_MAXTIME` | `0` (infinite) | Max time to wait for services to start |

## Utility Commands

Since the ENTRYPOINT is `/init` (s6-overlay), utility commands are run by overriding the entrypoint:

```bash
# Get auth token (interactive)
docker run --rm -it --entrypoint get-token <image>

# List remote vaults
docker run --rm -e OBSIDIAN_AUTH_TOKEN=... --entrypoint ob <image> sync-list-remote

# Run any ob subcommand
docker run --rm -e OBSIDIAN_AUTH_TOKEN=... --entrypoint ob <image> <subcommand>
```

This bypasses s6-overlay entirely, running the command directly without the init system or service chain.

## References

- [s6-overlay GitHub](https://github.com/just-containers/s6-overlay)
- [s6-rc documentation](https://skarnet.org/software/s6-rc/)
- [s6-rc source definition format](https://skarnet.org/software/s6-rc/s6-rc-compile.html)
- [obsidian-headless](https://github.com/obsidianmd/obsidian-headless)
