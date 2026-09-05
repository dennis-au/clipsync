# ClipSync macOS Status Utility: Discussion Result

Date: September 5, 2026

## Decision

- Build a personal macOS 13+ menu-bar utility for controlling the local ClipSync Docker stack.
- Use native SwiftUI `MenuBarExtra` with `LSUIElement`; it stays in the menu bar and has no Dock icon.
- Distribute it as a personal, Developer-ID-signed, non-sandboxed app. A Mac App Store sandbox is not an appropriate fit for direct Docker CLI/socket control.
- The utility controls the existing project at `/Users/dennisau/project/clipsync` after first-run confirmation. A later folder move requires re-approval.

## V1 Menu

- Start ClipSync
- Stop ClipSync
- Restart ClipSync
- Open local ClipSync (`http://127.0.0.1:8788`)
- Open public ClipSync (an optional URL configured in Settings)
- Open Docker Desktop
- Settings
- Quit

- Launch at Login is opt-in. It launches only the utility, never ClipSync automatically.
- Normal Stop and Restart do not need confirmation. Stop shows a clear warning that live connections and in-progress uploads will be interrupted.
- No log viewer, image updater, Docker updater, multi-project support, force-stop, or destructive cleanup in v1.

## Service Contract

- Start controls both services: `clipboard` and the profile-gated `cloudflared` tunnel.
- Stop uses Compose `stop` with a graceful timeout. It must preserve stopped containers, the `clipboard-data` volume, and all stored room data.
- The utility must never use `down -v`, `rm -v`, `prune`, volume deletion, or automatic rebuild/pull/update commands.
- Start uses fixed Docker Compose arguments with the approved absolute project directory, `compose.yaml`, and `.env`; it never runs a shell command string.
- If a required local image is missing, the utility asks once before explicitly preparing only the missing image. Existing image tags are never refreshed automatically.
- A single serialized operation controller prevents duplicate Start/Stop/Restart commands. Canceling a progress view stops waiting; it does not assume or alter the Docker operation.
- Start waits up to 120 seconds for health. Timeout becomes an actionable manual retry state, not an automatic restart loop.
- Docker's existing `restart: unless-stopped` policy remains unchanged. An explicit Stop should remain stopped after Docker Desktop restarts.

## Status Model

- Off
- Docker unavailable
- Starting
- Stopping
- Clipboard unhealthy
- Local healthy, tunnel stopped
- Local healthy, tunnel process running, public endpoint unconfigured or unverified
- Local healthy, public probe failing
- Healthy and publicly reachable
- Error

- Health is evaluated independently from Compose container state, local `http://127.0.0.1:8788/healthz`, and the optional public health URL.
- A running `cloudflared` container is not proof that the public site is reachable.
- The menu icon is a template icon with an accessible text label. It must never claim public availability based only on local health.
- Open local and Open public remain separate commands. Local is the safe default; public is used only when intentionally selected.

## Security And Privacy

- No administrator prompt, root helper, AppleScript, `sudo`, remote Docker context, or stored password/tunnel token.
- Docker is discovered only from approved absolute executable paths or an explicitly approved user-selected executable.
- The project directory is resolved to its real path and revalidated before every action. The utility requires expected files and safe ownership/permissions, and requests fresh approval if file identity changes.
- Child processes receive a minimal controlled environment and fixed argv arrays. No `sh -c`, shell aliases, inherited terminal commands, or user-entered Docker arguments.
- The utility does not read, display, or persist `.env` contents. It stores only non-secret preferences such as the approved path, Docker path, optional public URL, and launch-at-login choice.
- Diagnostics are sanitized summaries only: action, timestamp, safe failure category, and health state. Raw Compose output, container logs, clipboard content, filenames, and secrets are excluded.

## Failure Handling

- Docker Desktop unavailable: offer Open Docker Desktop and wait for the daemon; never automate sign-in or permission dialogs.
- Invalid/missing `.env` or Compose file, missing image, permission denial, port `8788` collision, unhealthy service, no network, and tunnel failure each get a distinct non-secret message and recovery action.
- A tunnel failure leaves a locally healthy ClipSync service usable; it is shown as partial success rather than a total failure.
- Stop during an upload or live session is allowed but explicitly warns that transfers and connections are interrupted.

## Architecture

- `StatusStore` on the main actor owns visible state.
- `StackOperationCoordinator` actor serializes Start, Stop, Restart, timeout, and cancellation behavior.
- `DockerClient` only builds vetted commands; `HealthProbe` checks Compose, local health, and optional public health; `ConfigApprovalStore` keeps non-secret approval metadata.
- Background checks are bounded adaptive polling. They observe state but never continuously attempt to repair or restart the stack.

## Verification Before Release

- Unit tests cover fixed command construction, path validation, approval changes, state transitions, cancellation, operation serialization, and diagnostic redaction.
- Integration tests use a disposable Compose fixture to prove Start is idempotent, Stop/Start preserves a stored item in the named volume, and Restart returns to healthy state.
- Manual tests cover Docker Desktop closed, invalid configuration, moved folder, permission error, port collision, missing image with no network, bad tunnel token, failed public DNS/reachability, slow startup, rapid menu clicks, utility relaunch, Docker Desktop restart, and active-transfer Stop warning.
- The release check includes an assertion that no destructive Docker command can be constructed by the utility.

## Deferred Decisions

- Keep this personal-only for v1. General distribution, notarized update delivery, and a sandbox-compatible architecture are later work.
- Confirm the public URL and whether Open public should be shown by default or enabled in Settings.
- Consider later: redacted diagnostic logs, notifications, transfer-awareness, multiple projects, and controlled image updates.
