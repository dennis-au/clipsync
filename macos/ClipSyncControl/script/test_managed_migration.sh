#!/usr/bin/env bash
set -euo pipefail

# Isolated Docker Desktop migration integration. It creates a temporary legacy
# Compose project and an external volume with a unique prefix, seeds actual room
# metadata plus a sentinel blob, stops legacy, and starts the managed Compose
# resource against the exact same external volume. It never references the real
# `clipsync` project or `clipsync_clipboard-data` volume, and retains only its
# uniquely named test volume for inspection after success.

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MANAGED_SOURCE="$ROOT_DIR/Sources/ClipSyncControl/Resources/managed-compose.yaml"
IMAGE="${CLIPSYNC_TEST_IMAGE:-ghcr.io/dennis-au/clipsync:v0.3.0}"
ID="clipsync-integration-$(uuidgen | tr '[:upper:]' '[:lower:]')"
VOLUME="${ID}-data"
LEGACY_PORT="$((20000 + RANDOM % 10000))"
MANAGED_PORT="$((30001 + RANDOM % 10000))"
WORKSPACE="$(mktemp -d)"
LEGACY_FILE="$WORKSPACE/legacy-compose.yaml"
MANAGED_FILE="$WORKSPACE/managed-compose.yaml"
ENV_FILE="$WORKSPACE/test.env"
PASSWORD="integration-password"
COOKIE="$(printf %s "$PASSWORD" | shasum -a 256 | awk '{print $1}')"

cleanup() {
  docker compose --project-name "$ID-managed" --project-directory "$WORKSPACE" --env-file "$ENV_FILE" -f "$MANAGED_FILE" stop >/dev/null 2>&1 || true
  docker compose --project-name "$ID-legacy" --project-directory "$WORKSPACE" --env-file "$ENV_FILE" -f "$LEGACY_FILE" stop >/dev/null 2>&1 || true
  rm -rf "$WORKSPACE"
}
trap cleanup EXIT

wait_for_health() {
  local port="$1"
  for _ in $(seq 1 60); do
    if curl --fail --silent "http://127.0.0.1:$port/healthz" | grep -qx ok; then return 0; fi
    sleep 2
  done
  return 1
}

docker info >/dev/null
docker pull "$IMAGE" >/dev/null
docker volume create "$VOLUME" >/dev/null
# ClipSync runs as UID/GID 10001. Seed the external volume with the same ownership
# and permissions it receives from the production image, rather than leaving a
# root-owned sentinel that prevents the legacy service from writing room data.
docker run --rm -v "$VOLUME:/data" busybox sh -c 'chown 10001:10001 /data && chmod 700 /data && printf migration-sentinel >/data/migration-sentinel && chown 10001:10001 /data/migration-sentinel && chmod 600 /data/migration-sentinel'

cat >"$LEGACY_FILE" <<EOF
services:
  legacy-clipboard:
    image: $IMAGE
    environment:
      CLIPSYNC_PASSWORD: \${CLIPSYNC_PASSWORD}
    ports: ["127.0.0.1:$LEGACY_PORT:8787"]
    volumes: ["clipboard-data:/var/lib/clipsync"]
    healthcheck:
      test: ["CMD-SHELL", "wget -qO- http://127.0.0.1:8787/healthz | grep -qx ok"]
      interval: 2s
      timeout: 2s
      retries: 10
volumes:
  clipboard-data:
    external: true
    name: $VOLUME
EOF
# The production Compose resource reserves an address range for cloudflared.
# This local-only migration test has no tunnel and lets Docker allocate a unique
# network instead, so it cannot overlap an already-running ClipSync stack.
sed \
  -e "s/name: clipsync_clipboard-data/name: $VOLUME/" \
  -e "s/127.0.0.1:8788:8787/127.0.0.1:$MANAGED_PORT:8787/" \
  -e '/^        ipv4_address: 172.31.0.[23]$/d' \
  -e '/^    ipam:$/,/^        - subnet:/d' \
  "$MANAGED_SOURCE" >"$MANAGED_FILE"
printf 'CLIPSYNC_IMAGE=%s\nCLIPSYNC_PASSWORD=%s\n' "$IMAGE" "$PASSWORD" >"$ENV_FILE"
chmod 600 "$LEGACY_FILE" "$MANAGED_FILE" "$ENV_FILE"

docker compose --project-name "$ID-legacy" --project-directory "$WORKSPACE" --env-file "$ENV_FILE" -f "$LEGACY_FILE" config --quiet
docker compose --project-name "$ID-managed" --project-directory "$WORKSPACE" --env-file "$ENV_FILE" -f "$MANAGED_FILE" config --quiet
docker compose --project-name "$ID-legacy" --project-directory "$WORKSPACE" --env-file "$ENV_FILE" -f "$LEGACY_FILE" up -d --no-build --pull never
wait_for_health "$LEGACY_PORT"
curl --fail --silent -X POST -H 'X-Kind: text' -H "Cookie: clip_auth=$COOKIE" --data 'migration room item' "http://127.0.0.1:$LEGACY_PORT/push?room=migration-room" >/dev/null
curl --fail --silent -H "Cookie: clip_auth=$COOKIE" "http://127.0.0.1:$LEGACY_PORT/list?room=migration-room" | grep -q 'migration room item'

# This is the same non-destructive legacy transition used by the controller.
docker compose --project-name "$ID-legacy" --project-directory "$WORKSPACE" --env-file "$ENV_FILE" -f "$LEGACY_FILE" stop
! docker compose --project-name "$ID-legacy" --project-directory "$WORKSPACE" --env-file "$ENV_FILE" -f "$LEGACY_FILE" ps --status running --services | grep -q legacy-clipboard
docker compose --project-name "$ID-managed" --project-directory "$WORKSPACE" --env-file "$ENV_FILE" -f "$MANAGED_FILE" up -d --no-build --pull never managed-clipboard
wait_for_health "$MANAGED_PORT"
curl --fail --silent -H "Cookie: clip_auth=$COOKIE" "http://127.0.0.1:$MANAGED_PORT/list?room=migration-room" | grep -q 'migration room item'
docker run --rm -v "$VOLUME:/data" busybox sh -c 'test "$(cat /data/migration-sentinel)" = migration-sentinel'

echo "PASS: legacy stop, room metadata, sentinel data, and managed health succeeded for $ID"
echo "Retained isolated volume for inspection: $VOLUME"
