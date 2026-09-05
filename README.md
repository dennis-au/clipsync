# clipsync

A tiny, self-hosted **shared clipboard for the browser**. Paste text or images in one
tab and they appear live in every other tab in the same room — on any machine, any
network, with nothing to install beyond a web browser.

Built as a single ~5 MB Go binary with **no external dependencies**. It was made to
move copy/paste between VMs on isolated corporate networks, a homelab and personal
machines, where a normal clipboard sync tool can't reach.

## Features

- **Live sync over SSE** (chosen over WebSockets to survive corporate proxies), with
  a polling fallback.
- **Text, images, and files** — paste, drag & drop, or choose files. Every upload is
  an atomic, recoverable item in a shared history.
- **Rooms**: content is scoped by a room code, so separate groups never mix.
- **Pin & expiry**: pinned items never expire or get evicted; each room has bounded
  pinned and unpinned history, and unpinned items are swept after a configurable TTL.
- **Durable persistence**: serialized, atomic metadata snapshots survive restarts;
  the prior valid snapshot is retained for automatic recovery if the primary JSON
  file is corrupted or unreadable. PNG, JPEG, GIF, and WebP uploads are checked
  against their declared format signature before being retained. This is file-type
  validation, not malware scanning; arbitrary files remain downloadable attachments.
- **Password-protected** with a shared secret, plus per-IP rate limiting and a disk
  cap as defence in depth.

## Quick start

```bash
go build -o clipsync .
CLIPSYNC_PASSWORD=change-me ./clipsync
# open http://localhost:8787
```

Pick a room code (it lives in the URL fragment, e.g. `http://localhost:8787/#myroom`)
and open the same URL on another machine to sync.

### Docker

Build an image locally, copy the safe example environment file, and set a real
password before starting the example Compose stack:

```bash
docker build -t clipsync:local .
cp .env.example .env
# Edit .env and replace CLIPSYNC_PASSWORD.
docker compose -f compose.example.yaml up -d
```

The service is then available only at `http://127.0.0.1:8787`. For a published
image, Cloudflare Tunnel, upgrades, and backup guidance, read
[DEPLOYMENT.md](DEPLOYMENT.md). `compose.yaml` and `.env` are intentionally
operator-owned files and are not part of this repository.

### macOS status utility

[`macos/ClipSyncControl`](macos/ClipSyncControl) is a native menu-bar utility for
the operator-owned local Compose stack. It safely starts, stops, and restarts the
clipboard and tunnel, can copy the current shared password, and can generate a new
password then recreate the stack to apply it. Password rotation changes only
`CLIPSYNC_PASSWORD` in `.env`; it never changes `compose.yaml` or the persistent
volume. Its Stop command preserves room data. Build and launch it locally with:

```bash
cd macos/ClipSyncControl
./script/build_and_run.sh --verify
```

Approve the project folder in the utility's Settings before it can control Docker.

## Configuration

All configuration is via environment variables:

| Variable | Default | Description |
|----------|---------|-------------|
| `CLIPSYNC_PASSWORD` | *(required)* | Shared password. The server refuses to start without it unless the explicit local-development opt-in below is used. |
| `CLIPSYNC_ALLOW_NO_AUTH` | *(none)* | Set exactly to `1` only for an isolated local-development experiment. Never use it with Docker Compose, a tunnel, or a reverse proxy. |
| `CLIPSYNC_ADDR` | `:8787` | Listen address. |
| `CLIPSYNC_STATE` | `/var/lib/clipsync` | Directory for persisted metadata and binary blobs. |
| `CLIPSYNC_TTL_DAYS` | `180` | Days after which un-pinned items are swept. |
| `CLIPSYNC_MAX_DISK_MB` | `1024` | Disk cap for stored blobs and in-progress file uploads; uploads are rejected with HTTP 507 when full. |
| `CLIPSYNC_MAX_TEXT_MB` | `64` | Maximum size of one text item. |
| `CLIPSYNC_TEXT_INLINE_KB` | `64` | Maximum text kept in room metadata. Larger text is stored as a private blob while list and live views retain a bounded preview. |
| `CLIPSYNC_MAX_IMAGE_MB` | `64` | Maximum size of one PNG, JPEG, GIF, or WebP image. |
| `CLIPSYNC_MAX_FILE_MB` | `64` | Maximum size of one arbitrary file; file data streams to disk instead of being held in memory. |
| `CLIPSYNC_UPLOAD_CHUNK_MB` | `32` | Browser upload request size for arbitrary files. |
| `CLIPSYNC_UPLOAD_TTL_MINUTES` | `15` | Inactivity window for a resumable file upload; expired staging files are removed at most one minute later. |
| `CLIPSYNC_UPLOAD_CHUNK_IDLE_SECONDS` | `120` | Maximum gap while receiving a resumable chunk; a stalled chunk is aborted and its session capacity is released. |
| `CLIPSYNC_MAX_UPLOADS` | `16` | Maximum active resumable uploads across the server. |
| `CLIPSYNC_MAX_UPLOADS_PER_CLIENT` | `2` | Maximum active resumable uploads for one rate-limit client identity. |
| `CLIPSYNC_MAX_UPLOADS_PER_ROOM` | `4` | Maximum active resumable uploads targeting one room. |
| `CLIPSYNC_MAX_ROOMS` | `128` | Maximum number of non-empty rooms held by the server. Reads of an unknown room do not create it. |
| `CLIPSYNC_MAX_ROOM_NAME_BYTES` | `64` | Maximum room-code length. Codes may contain only letters, digits, `.`, `_`, and `-`. |
| `CLIPSYNC_MAX_ITEMS_PER_ROOM` | `80` | Hard cap on all items in one room, including pinned items. |
| `CLIPSYNC_MAX_UNPINNED_ITEMS_PER_ROOM` | `60` | Maximum unpinned items retained in one room; older unpinned items are evicted first. |
| `CLIPSYNC_MAX_PINNED_ITEMS_PER_ROOM` | `20` | Maximum pinned items in one room. Pinning past this cap is rejected. |
| `CLIPSYNC_TRUSTED_PROXY_CIDRS` | *(none)* | Comma-separated connector IPs/CIDRs that may supply `CF-Connecting-IP`. All other peers, including direct local requests, use their socket IP and ignore forwarding headers. |
| `CLIPSYNC_MAX_SSE` | `128` | Maximum concurrent live SSE connections. |
| `CLIPSYNC_MAX_SSE_PER_CLIENT` | `4` | Maximum concurrent live SSE connections for one client identity. |

Limits: by default, a room holds at most 80 items, including at most 60 unpinned and 20 pinned items. Pinned items are retained until explicitly unpinned or the room is cleared. New pushes evict the oldest unpinned item when possible; a room that contains only pinned items rejects another push.

## Persistence and recovery

Metadata is written as a private, fsynced temporary file in `CLIPSYNC_STATE`, then
atomically renamed to `items.json`. A second atomic write keeps `items.json.bak` as
an independent copy of the newest complete snapshot. On startup, a corrupt or
unreadable primary is recovered from the backup and rewritten when possible.
Obsolete blobs from a clear, expiry, or eviction are removed only after that
replacement snapshot is durable, so a failed write leaves the previous on-disk
history restartable.

If a mutation cannot be made durable, clipsync returns HTTP `503` with
`X-Clipsync-Persistence: failed`. The change remains usable in the live process but
may be lost on a restart, so fix the storage problem and refresh rather than retrying
the action blindly. Server logs include the underlying filesystem error.

## Encrypted Docker volume backups

The Docker deployment keeps all clipboard content in its named volume. The
`scripts/backup-volume.sh` workflow stops the clipboard container briefly when it
is running, streams a tar archive directly through `age`, and writes only encrypted
`*.tar.gz.age` files on the host. Install `age` first, then keep its private identity
key outside this repository.

```sh
export CLIPSYNC_BACKUP_DIR="$HOME/.local/share/clipsync-backups"
export CLIPSYNC_BACKUP_AGE_RECIPIENT='age1...your-public-recipient...'
# Optional. Leave unset to retain every encrypted backup.
export CLIPSYNC_BACKUP_RETENTION_DAYS=30
./scripts/backup-volume.sh
```

The script discovers the volume attached to the Compose `clipboard` container. Set
`CLIPSYNC_BACKUP_VOLUME` only when an explicit override is required. Retention
deletion is disabled unless `CLIPSYNC_BACKUP_RETENTION_DAYS` is explicitly set to a
positive number. The script only deletes matching encrypted backup files directly
inside the selected absolute backup directory.

To restore, first make a fresh encrypted backup of the current volume. Stop sharing
the clipboard while the restore is in progress, then provide the private `age`
identity and the required confirmation string:

```sh
export CLIPSYNC_AGE_IDENTITY_FILE="$HOME/.config/age/keys.txt"
export CLIPSYNC_RESTORE_CONFIRM=RESTORE
./scripts/restore-volume.sh /absolute/path/to/clipsync-volume-YYYYMMDDTHHMMSSZ.tar.gz.age
docker compose ps
curl -fsS http://127.0.0.1:8787/healthz
```

The restore script creates and retains a rollback Docker volume before replacing
the live volume. Remove that rollback volume manually only after the health check
and expected room history have been verified.

## Deploying behind a reverse proxy

clipsync streams updates via Server-Sent Events, so disable response buffering on your
proxy or live updates will stall. For nginx:

```nginx
proxy_buffering off;
```

When placing clipsync behind a proxy, configure `CLIPSYNC_TRUSTED_PROXY_CIDRS` with
only that proxy's fixed origin address. The server accepts `CF-Connecting-IP` only
from those peers and intentionally ignores `X-Forwarded-For`.

## API

The web UI is served from `/`. Endpoints:

- `GET /list?room=` — current items in a room
- `POST /push` — add an item (headers `X-Kind: text|image|file`, `X-Mime`, `X-Name`, `X-From`)
- `POST /upload/start`, `/upload/chunk`, `/upload/complete` — resumable arbitrary-file upload flow used by the web UI
- `GET /item?room=&id=` — full text of an item
- `GET /blob?room=&id=` — raw bytes of an image or downloadable file item
- `GET /events?room=` — SSE stream (snapshot + live pushes)
- `POST /pin?room=&id=&pin=1|0` — pin / unpin an item
- `POST /clear?room=` — permanently remove every item from a room
- `POST /login` — form field `password`; sets an auth cookie
- `POST /logout`

## License

MIT — see [LICENSE](LICENSE).
