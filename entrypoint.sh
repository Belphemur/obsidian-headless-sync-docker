#!/bin/sh
set -e

# Subcommand dispatch — lets helpers and raw ob commands be called directly:
#   docker run --rm -it <image> get-token
#   docker run --rm -it <image> ob sync-list-remote
case "$1" in
  get-token)
    exec /usr/local/bin/get-token
    ;;
  ob)
    shift
    exec ob "$@"
    ;;
  "")
    ;;   # fall through to sync logic below
  *)
    exec "$@"
    ;;
esac

VAULT_PATH="${VAULT_PATH:-/vault}"

# Validate required env vars
if [ -z "$OBSIDIAN_AUTH_TOKEN" ]; then
  echo "[obsidian-headless] ERROR: OBSIDIAN_AUTH_TOKEN is not set." >&2
  echo "[obsidian-headless] Run the following to get your token:" >&2
  echo "[obsidian-headless]   docker run --rm -it <image> get-token" >&2
  exit 1
fi

mkdir -p "$VAULT_PATH"
cd "$VAULT_PATH"

# First-time vault setup: link local directory to remote vault
if [ -n "$VAULT_NAME" ]; then
  echo "[obsidian-headless] Configuring sync for vault: '$VAULT_NAME' → $VAULT_PATH"
  SETUP_CMD="ob sync-setup --vault \"$VAULT_NAME\""
  if [ -n "$VAULT_PASSWORD" ]; then
    SETUP_CMD="$SETUP_CMD --password \"$VAULT_PASSWORD\""
  fi
  if ! eval "$SETUP_CMD"; then
    echo "[obsidian-headless] ERROR: ob sync-setup failed." >&2
    echo "[obsidian-headless] Check OBSIDIAN_AUTH_TOKEN and VAULT_NAME are correct." >&2
    if [ -z "$VAULT_PASSWORD" ]; then
      echo "[obsidian-headless] If your vault uses end-to-end encryption, set VAULT_PASSWORD." >&2
    fi
    exit 1
  fi
fi

# Apply optional sync config
if [ -n "$DEVICE_NAME" ]; then
  ob sync-config --device-name "$DEVICE_NAME" 2>/dev/null || true
fi

if [ -n "$CONFLICT_STRATEGY" ]; then
  ob sync-config --conflict-strategy "$CONFLICT_STRATEGY" 2>/dev/null || true
fi

if [ -n "$EXCLUDED_FOLDERS" ]; then
  ob sync-config --excluded-folders "$EXCLUDED_FOLDERS" 2>/dev/null || true
fi

if [ -n "$FILE_TYPES" ]; then
  ob sync-config --file-types "$FILE_TYPES" 2>/dev/null || true
fi

echo "[obsidian-headless] Starting continuous sync..."
exec ob sync --continuous
