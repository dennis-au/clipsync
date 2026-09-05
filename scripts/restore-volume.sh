#!/usr/bin/env bash
set -euo pipefail
umask 077

die() {
  printf '%s\n' "restore-volume: $*" >&2
  exit 1
}

[[ $# -eq 1 ]] || die "usage: CLIPSYNC_AGE_IDENTITY_FILE=/path/to/key CLIPSYNC_RESTORE_CONFIRM=RESTORE $0 /absolute/path/to/clipsync-volume-...tar.gz.age"
repo_root=$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
compose_file="$repo_root/compose.yaml"
identity_file=${CLIPSYNC_AGE_IDENTITY_FILE:?Set CLIPSYNC_AGE_IDENTITY_FILE to the age private-key file}
backup_input=$1

case "$backup_input" in
  /*) ;;
  *) die "backup path must be absolute" ;;
esac
[[ "${CLIPSYNC_RESTORE_CONFIRM:-}" == "RESTORE" ]] || die "set CLIPSYNC_RESTORE_CONFIRM=RESTORE after taking a fresh backup"
command -v age >/dev/null || die "age is required"
command -v docker >/dev/null || die "docker is required"
[[ -f "$compose_file" ]] || die "compose file not found: $compose_file"
[[ -f "$identity_file" ]] || die "age identity file not found: $identity_file"

backup_dir=$(cd -- "$(dirname -- "$backup_input")" && pwd -P)
backup_file="$backup_dir/$(basename -- "$backup_input")"
[[ ! -L "$backup_file" && -f "$backup_file" ]] || die "backup must be a regular, non-symlink file"
case "$(basename -- "$backup_file")" in
  clipsync-volume-*.tar.gz.age) ;;
  *) die "backup filename does not match the encrypted clipsync backup format" ;;
esac

compose() {
  docker compose --project-directory "$repo_root" -f "$compose_file" "$@"
}

container_id=$(compose ps --all -q clipboard)
[[ -n "$container_id" ]] || die "clipboard container does not exist; start the stack before restoring"
volume=${CLIPSYNC_BACKUP_VOLUME:-}
if [[ -z "$volume" ]]; then
  volume=$(docker inspect --format '{{range .Mounts}}{{if and (eq .Type "volume") (eq .Destination "/var/lib/clipsync")}}{{.Name}}{{end}}{{end}}' "$container_id")
fi
case "$volume" in
  ''|*[!A-Za-z0-9_.-]*) die "could not resolve a safe clipboard Docker volume name" ;;
esac
docker volume inspect "$volume" >/dev/null || die "Docker volume not found: $volume"
was_running=$(docker inspect --format '{{.State.Running}}' "$container_id")
[[ "$was_running" == "true" || "$was_running" == "false" ]] || die "could not determine clipboard container state"

suffix="$(date -u +%Y%m%dT%H%M%SZ)-$$-$RANDOM"
staging_volume="${volume}-restore-${suffix}"
rollback_volume="${volume}-rollback-${suffix}"
service_stopped=0
rollback_created=0

cleanup() {
  local status=$?
  docker volume rm "$staging_volume" >/dev/null 2>&1 || true
  if [[ "$service_stopped" == "1" ]]; then
    compose start clipboard || printf '%s\n' "restore-volume: could not restart clipboard; run docker compose start clipboard" >&2
  fi
  if [[ "$rollback_created" == "1" ]]; then
    printf 'Rollback volume retained: %s\n' "$rollback_volume" >&2
  fi
  exit "$status"
}
trap cleanup EXIT

docker volume create "$staging_volume" >/dev/null
age --decrypt -i "$identity_file" "$backup_file" | docker run --rm -i -v "$staging_volume":/data alpine:3.22 tar -C /data -xzf -

if [[ "$was_running" == "true" ]]; then
  compose stop clipboard
  service_stopped=1
fi

# Keep a volume-level rollback copy before replacing the live contents.
docker volume create "$rollback_volume" >/dev/null
rollback_created=1
docker run --rm -v "$volume":/source:ro -v "$rollback_volume":/rollback alpine:3.22 \
  sh -eu -c 'cp -a /source/. /rollback/'
docker run --rm -v "$volume":/target -v "$staging_volume":/stage:ro alpine:3.22 \
  sh -eu -c 'rm -rf /target/* /target/.[!.]* /target/..?*; cp -a /stage/. /target/; chown -R 10001:10001 /target'

if [[ "$service_stopped" == "1" ]]; then
  compose start clipboard
  service_stopped=0
fi

trap - EXIT
docker volume rm "$staging_volume" >/dev/null
printf 'Restored encrypted backup. Keep rollback volume %s until the service health check passes.\n' "$rollback_volume"
