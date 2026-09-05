#!/usr/bin/env bash
set -euo pipefail

repo_root=$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
backup_script="$repo_root/scripts/backup-volume.sh"
restore_script="$repo_root/scripts/restore-volume.sh"

bash -n "$backup_script" "$restore_script"
grep -Fq 'tar -C /data -czf - . | age -r "$recipient" -o "$tmp_file"' "$backup_script"
grep -Fq 'ln -- "$tmp_file" "$backup_file"' "$backup_script"
grep -Fq 'CLIPSYNC_BACKUP_RETENTION_DAYS' "$backup_script"
grep -Fq 'CLIPSYNC_RESTORE_CONFIRM' "$restore_script"
grep -Fq 'Rollback volume retained' "$restore_script"
grep -Fq 'docker inspect --format' "$backup_script"
printf '%s\n' 'backup workflow structure checks passed'
