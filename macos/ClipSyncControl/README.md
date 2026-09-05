# ClipSync Control

ClipSync Control is a personal macOS menu-bar utility for the Docker Compose stack in this repository.

It starts, stops, and restarts the local `clipboard` and Cloudflare tunnel services. It can copy the current shared password or generate a new cryptographically secure password and recreate the stack to apply it. Password rotation changes only `CLIPSYNC_PASSWORD` in `.env`; it never changes `compose.yaml` or removes the `clipboard-data` volume. Stop uses `docker compose stop`; it never removes stored ClipSync data.

## Run locally

```bash
cd macos/ClipSyncControl
./script/build_and_run.sh --verify
```

The first launch requires approval of the ClipSync project folder in Settings. The app re-checks file ownership, safe permissions, and the Compose file fingerprint before it sends a Docker command.

The build script creates a local bundle at `dist/ClipSyncControl.app`. It is intended for local development until signed and notarized for distribution.
