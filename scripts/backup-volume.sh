#!/usr/bin/env bash
set -euo pipefail
umask 077

die() {
  printf '%s\n' "backup-volume: $*" >&2
  exit 1
}

repo_root=$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
compose_file="$repo_root/compose.yaml"
backup_dir=${CLIPSYNC_BACKUP_DIR:?Set CLIPSYNC_BACKUP_DIR to an absolute backup directory}
recipient=${CLIPSYNC_BACKUP_AGE_RECIPIENT:?Set CLIPSYNC_BACKUP_AGE_RECIPIENT to an age recipient}
retention_days=${CLIPSYNC_BACKUP_RETENTION_DAYS:-}

case "$backup_dir" in
  /*) ;;
  *) die "CLIPSYNC_BACKUP_DIR must be an absolute path" ;;
esac
if [[ -n "$retention_days" && ! "$retention_days" =~ ^[1-9][0-9]*$ ]]; then
  die "CLIPSYNC_BACKUP_RETENTION_DAYS must be a positive whole number when set"
fi
command -v age >/dev/null || die "age is required; install it before creating backups"
command -v docker >/dev/null || die "docker is required"
[[ -f "$compose_file" ]] || die "compose file not found: $compose_file"

mkdir -p -- "$backup_dir"
backup_dir=$(cd -- "$backup_dir" && pwd -P)
[[ "$backup_dir" != "/" ]] || die "refusing to use / as the backup directory"
chmod 700 -- "$backup_dir"

compose() {
  docker compose --project-directory "$repo_root" -f "$compose_file" "$@"
}

container_id=$(compose ps --all -q clipboard)
[[ -n "$container_id" ]] || die "clipboard container does not exist; start the stack before backing it up"
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

timestamp=$(date -u +%Y%m%dT%H%M%SZ)
backup_file="$backup_dir/clipsync-volume-$timestamp.tar.gz.age"
work_dir=$(mktemp -d "$backup_dir/.clipsync-backup.XXXXXX")
tmp_file="$work_dir/archive.tar.gz.age"
service_stopped=0

cleanup() {
  local status=$?
  rm -rf -- "$work_dir"
  if [[ "$service_stopped" == "1" ]]; then
    compose start clipboard || printf '%s\n' "backup-volume: could not restart clipboard; run docker compose start clipboard" >&2
  fi
  exit "$status"
}
trap cleanup EXIT

if [[ "$was_running" == "true" ]]; then
  compose stop clipboard
  service_stopped=1
fi

# The tar stream stays inside Docker until age encrypts it; only ciphertext reaches the host.
docker run --rm -v "$volume":/data:ro alpine:3.22 \
  tar -C /data -czf - . | age -r "$recipient" -o "$tmp_file"
[[ -s "$tmp_file" ]] || die "encryption produced an empty backup"
# tmp_file lives under backup_dir, so this hard link is an atomic no-clobber
# publish. A concurrent backup using the same second-based name fails safely.
ln -- "$tmp_file" "$backup_file" || die "backup filename already exists: $backup_file"
rm -- "$tmp_file"

if [[ "$service_stopped" == "1" ]]; then
  compose start clipboard
  service_stopped=0
fi

if [[ -n "$retention_days" ]]; then
  find "$backup_dir" -maxdepth 1 -type f -name 'clipsync-volume-*.tar.gz.age' -mtime +"$retention_days" -print -delete
fi

trap - EXIT
rm -rf -- "$work_dir"
printf 'Created encrypted backup: %s\n' "$backup_file"
if [[ -z "$retention_days" ]]; then
  printf '%s\n' 'Retention is disabled; set CLIPSYNC_BACKUP_RETENTION_DAYS to enable deletion of old encrypted backups.'
fi
