# obsidian-headless-sync-docker

A minimal, rootless Docker image for continuously syncing an [Obsidian](https://obsidian.md) vault via [obsidian-headless](https://github.com/obsidianmd/obsidian-headless) — the official headless client for Obsidian Sync released February 2026.

Built on [s6-overlay](https://github.com/just-containers/s6-overlay) for proper process supervision, signal handling, and ordered service startup. The container starts as root to perform one-time user/group and ownership setup, then runs the main services as a non-root user.

**Requirements:** An active [Obsidian Sync](https://obsidian.md/sync) subscription.

---

## Quick Start

### Step 1 — Get your auth token (one-time)

Pull the image and run the interactive login helper. It will prompt for your Obsidian email, password, and MFA code (if enabled), then print your token.

```bash
# Docker
docker run --rm -it --entrypoint get-token ghcr.io/belphemur/obsidian-headless-sync-docker:latest

# Podman
podman run --rm -it --entrypoint get-token ghcr.io/belphemur/obsidian-headless-sync-docker:latest
```

Copy the printed `OBSIDIAN_AUTH_TOKEN` value — you'll need it in step 3.

> **Note:** The token persists until you explicitly log out or revoke it from your Obsidian account. You only need to run this once per machine (or per token rotation).

---

### Step 2 — Find your remote vault name (one-time)

List the vaults available on your Obsidian Sync account:

```bash
# Docker
docker run --rm \
  -e OBSIDIAN_AUTH_TOKEN=your-token-here \
  --entrypoint ob \
  ghcr.io/belphemur/obsidian-headless-sync-docker:latest \
  sync-list-remote

# Podman
podman run --rm \
  -e OBSIDIAN_AUTH_TOKEN=your-token-here \
  --entrypoint ob \
  ghcr.io/belphemur/obsidian-headless-sync-docker:latest \
  sync-list-remote
```

Note the exact vault name — you'll use it in `VAULT_NAME`.

---

### Step 3 — Configure your environment

```bash
cp .env.example .env
```

Edit `.env` and fill in at minimum:

```env
OBSIDIAN_AUTH_TOKEN=<token from step 1>
VAULT_NAME=My Vault
VAULT_HOST_PATH=./vault
CONFIG_HOST_PATH=./config
```

See [Environment Variables](#environment-variables) for all options.

---

### Step 4 — Start continuous sync

```bash
docker compose up -d
```

On first run the container performs a one-time `ob sync-setup` to link the local directory to your remote vault, then enters continuous sync mode. Subsequent restarts skip the setup and go straight to syncing.

Watch logs:

```bash
docker compose logs -f
```

---

## Architecture

This image uses [s6-overlay v3](https://github.com/just-containers/s6-overlay) as its init system. See [`docs/s6-overlay-design.md`](docs/s6-overlay-design.md) for the full design documentation.

The startup sequence runs through ordered s6-rc services:

1. **init-setup-user** — adjusts UID/GID to match `PUID`/`PGID`
2. **init-check-auth** — validates `OBSIDIAN_AUTH_TOKEN` is set
3. **init-obsidian-login** — runs `ob login` to authenticate
4. **init-setup-vault** — runs `ob sync-setup` and applies optional config
5. **svc-obsidian-sync** — starts `ob sync --continuous` under s6 supervision

If any init step fails, the container exits immediately (`S6_BEHAVIOUR_IF_STAGE2_FAILS=2`).

Supported platforms: `linux/amd64`, `linux/arm64`.

---

## Environment Variables

| Variable | Required | Default | Description |
|---|---|---|---|
| `OBSIDIAN_AUTH_TOKEN` | Yes | — | Auth token from `get-token` |
| `VAULT_NAME` | Yes (first run) | — | Exact name of the remote Obsidian Sync vault |
| `VAULT_HOST_PATH` | Yes | `./vault` | Host path where vault files will be written |
| `CONFIG_HOST_PATH` | No | `./config` | Host path for persistent config (login state, etc.) |
| `VAULT_PASSWORD` | If E2E enabled | — | Vault end-to-end encryption password (see below) |
| `PUID` | No | `1000` | UID that will own synced files (see below) |
| `PGID` | No | `1000` | GID that will own synced files (see below) |
| `VAULT_PATH` | No | `/vault` | In-container mount path (advanced) |
| `DEVICE_NAME` | No | `obsidian-docker` | Label shown in Obsidian Sync history |
| `CONFLICT_STRATEGY` | No | `merge` | `merge` or `conflict` |
| `EXCLUDED_FOLDERS` | No | — | Comma-separated vault folders to skip |
| `FILE_TYPES` | No | — | Extra types to sync: `image,audio,video,pdf,unsupported` |
| `GHCR_REPO` | No | — | Override image repository when self-building |

---

## File Ownership (PUID / PGID)

At startup the container adjusts its internal `obsidian` user to match the `PUID`/`PGID` you provide, then drops privileges via `s6-setuidgid` before running any Obsidian commands. This means vault files on the host are owned by the UID/GID you choose.

**Regular Docker** (daemon runs as root):

```bash
# Find your UID and GID
id
# uid=1000(you) gid=1000(you) ...
```

```env
PUID=1000
PGID=1000
```

**Rootless Docker / Podman** (daemon runs as your user):

In rootless mode, container UID 0 already maps to your host user. Set both to `0`:

```env
PUID=0
PGID=0
```

---

## End-to-End Encryption (VAULT_PASSWORD)

Obsidian Sync supports optional end-to-end encryption with a separate vault password. If your vault has this enabled, `ob sync-setup` will fail to authenticate until the password is provided.

**To check:** In the Obsidian desktop app, go to **Settings → Sync** and look for an "Encryption password" field — if it's present and set, E2E is active.

Add the password to your `.env`:

```env
VAULT_PASSWORD=your-vault-encryption-password
```

> **Note:** `VAULT_PASSWORD` is the *vault encryption password* you chose in Obsidian, not your Obsidian account password. They are separate credentials.

---

## Using a Pre-Built Image vs. Building Locally

### Pre-built (recommended)

Images are published to the GitHub Container Registry on every push to `main` and on version tags. Multi-arch images are available for `linux/amd64` and `linux/arm64`.

```yaml
# compose.yml already points to:
image: ghcr.io/belphemur/obsidian-headless-sync-docker:latest
```

### Build locally

```bash
docker build -t obsidian-headless-sync-docker .
```

Then update `compose.yml` to use `image: obsidian-headless-sync-docker`.

---

## Podman Quadlet (systemd)

A ready-made quadlet unit file (`obsidian-sync.container`) is included for running the container as a systemd service under rootless Podman.

### Install

```bash
# Copy the quadlet into the user systemd search path
mkdir -p ~/.config/containers/systemd
cp obsidian-sync.container ~/.config/containers/systemd/

# Create a secrets file (mode 600 keeps your token private)
mkdir -p ~/.config/obsidian-sync
install -m 600 /dev/null ~/.config/obsidian-sync/obsidian-sync.env
```

Populate `~/.config/obsidian-sync/obsidian-sync.env` with at minimum:

```env
OBSIDIAN_AUTH_TOKEN=<token from get-token>
VAULT_NAME=My Vault
```

Optional keys (defaults are set in the unit file):

```env
VAULT_PASSWORD=
DEVICE_NAME=obsidian-podman
CONFLICT_STRATEGY=merge
EXCLUDED_FOLDERS=
FILE_TYPES=
```

### Start

```bash
systemctl --user daemon-reload
systemctl --user start obsidian-sync
systemctl --user status obsidian-sync
```

Watch logs:

```bash
journalctl --user -u obsidian-sync -f
```

### Automatic image updates

Enable the built-in Podman auto-update timer to pull new images from ghcr on a schedule:

```bash
systemctl --user enable --now podman-auto-update.timer
```

The unit also sets `Pull=newer`, so it will fetch a newer image from ghcr.io each time the service restarts.

### Vault location

By default the vault is stored at `~/obsidian-vault`. To use a different path, edit the `Volume=` line in the unit file before copying it:

```ini
Volume=/path/to/your/vault:/vault:z
```

---

## Updating the Image

```bash
docker compose pull
docker compose up -d
```

---

## Stopping

```bash
docker compose down
```

Your vault files remain on disk at `VAULT_HOST_PATH`.

---

## Troubleshooting

**Container exits immediately**
- Check that `OBSIDIAN_AUTH_TOKEN` and `VAULT_NAME` are set: `docker compose config`
- Check init logs: the container stops on any init failure (`S6_BEHAVIOUR_IF_STAGE2_FAILS=2`)

**"Vault not found" error on setup**
- Confirm the vault name matches exactly (case-sensitive): run `ob sync-list-remote` as shown in Step 2.

**"Failed to validate password" on setup**
- Your vault has end-to-end encryption enabled. Set `VAULT_PASSWORD` in `.env` to the encryption password from **Obsidian → Settings → Sync**. This is distinct from your Obsidian account password.

**Sync stops after a while**
- The `restart: unless-stopped` policy in `compose.yml` will restart the container automatically. Within the container, s6 supervises the sync process and restarts it if it exits.

**Token expired / login required**
- Re-run the `get-token` step, update `OBSIDIAN_AUTH_TOKEN` in `.env`, and restart: `docker compose up -d`

**Permission denied on vault files**
- The container adjusts its internal user to match `PUID`/`PGID` (default `1000:1000`). Set these in `.env` to match the host user who should own the files (`id` shows your values).
- For rootless Docker/Podman, set both to `0`.

---

## License

MIT
