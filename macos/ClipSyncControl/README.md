# ClipSync Control

ClipSync Control is a menu-bar utility that manages a private ClipSync Docker Compose workspace while continuing to rely on Docker Desktop.

The app stores its Compose resource in `~/Library/Application Support/ClipSync`, uses the fixed `clipsync` Compose project, and keeps the existing `clipsync_clipboard-data` Docker volume external. Start, stop, restart, password rotation, and room-data actions never run `down -v`, remove a Docker volume, or prune Docker resources.

On first migration, the app explicitly imports the legacy deployment password into the macOS Keychain, stops legacy containers, then launches distinct `managed-clipboard` and `managed-cloudflared` services against the existing data volume. The old repository and containers are kept available for rollback.

The Room Data settings pane lists every non-empty room in the local service. Rooms can be selected individually or in a batch and permanently deleted after an explicit confirmation. A separate force-delete action removes every room and incomplete upload. Room names and the deployment password remain local to the controller.
Administrative requests run through `docker compose exec` against the managed clipboard
container's loopback interface, so the destructive API remains unavailable from
the host port and public tunnel.

## Run locally

```bash
cd macos/ClipSyncControl
./script/build_and_run.sh --verify
```

Password and Cloudflare tunnel token are Keychain items (`clipboard-password` and `cloudflare-tunnel-token`). Compose reads a temporary user-only environment file for the duration of a command; the app removes it immediately and scrubs stale copies at launch. Secrets are not stored in UserDefaults, the app bundle, or the managed workspace.

Choose a stable ClipSync GHCR image from GitHub releases in Settings. Downloads and version changes are explicit; no image update is automatic. For a Cloudflare tunnel, create a remotely managed tunnel in the Cloudflare dashboard, map its hostname to `http://clipboard:8787`, then save the generated token in Settings. Enable Cloudflare Access before exposing ClipSync publicly.

The build script creates a local bundle at `dist/ClipSyncControl.app`. It is intended for local development until signed and notarized for distribution.

## Release artifact

On Apple Silicon, create a standalone `.app` and GitHub-ready ZIP with:

```bash
./script/package_release.sh 0.3.0
```

The output is `dist/release/ClipSyncControl-0.3.0-macos-arm64.zip`. The script
builds in release mode and validates a fresh ad-hoc code signature. It is a
developer artifact, not a Developer ID signed or notarized application; macOS may
require explicit user approval before its first launch.
