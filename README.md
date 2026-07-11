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
- **Text and images** — paste or drag & drop. Every paste is an atomic, recoverable
  item in a shared history.
- **Rooms**: content is scoped by a room code, so separate groups never mix.
- **Pin & expiry**: pinned items never expire or get evicted; everything else is
  capped (60 items/room) and swept after a configurable TTL.
- **Persistence**: survives restarts (metadata as JSON, image blobs on disk).
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

## Configuration

All configuration is via environment variables:

| Variable | Default | Description |
|----------|---------|-------------|
| `CLIPSYNC_PASSWORD` | *(none)* | Shared password. If unset, the server runs **without auth** — only do this on a trusted network. |
| `CLIPSYNC_ADDR` | `:8787` | Listen address. |
| `CLIPSYNC_STATE` | `/var/lib/clipsync` | Directory for persisted metadata and image blobs. |
| `CLIPSYNC_TTL_DAYS` | `180` | Days after which un-pinned items are swept. |
| `CLIPSYNC_MAX_DISK_MB` | `1024` | Disk cap for stored blobs; pushes are rejected with HTTP 507 when full. |

Limits: 60 items per room, 12 MiB per item, room codes must be at least 8 characters.

## Deploying behind a reverse proxy

clipsync streams updates via Server-Sent Events, so disable response buffering on your
proxy or live updates will stall. For nginx:

```nginx
proxy_buffering off;
```

## API

The web UI is served from `/`. Endpoints:

- `GET /list?room=` — current items in a room
- `POST /push` — add an item (headers `X-Kind: text|image`, `X-Mime`, `X-From`)
- `GET /item?room=&id=` — full text of an item
- `GET /blob?room=&id=` — raw bytes of an image item
- `GET /events?room=` — SSE stream (snapshot + live pushes)
- `POST /pin?room=&id=&pin=1|0` — pin / unpin an item
- `POST /login` — form field `password`; sets an auth cookie
- `POST /logout`

## License

MIT — see [LICENSE](LICENSE).
