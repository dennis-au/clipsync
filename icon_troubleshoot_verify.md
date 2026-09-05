# ClipSync Control Icon Troubleshooting and Verification

## Scope

Follow this protocol for every change or investigation involving the ClipSync
Control macOS menu-bar item. Do not report the icon as fixed based only on a
successful build, a running process, accessibility output, or an AppKit log.

The user-visible macOS menu bar is the final source of truth.

## Required Pass Criteria

All of the following must pass before an icon change is complete:

1. Exactly one `ClipSyncControl` process is running from the expected
   `dist/ClipSyncControl.app` bundle.
2. The visible macOS menu bar is deliberately revealed and captured at full
   desktop scale. The status item is clearly visible among the system icons.
3. The status item has the requested visual treatment. The current expected
   treatment is the overlapping-squares symbol without a text label.
4. Clicking the visible item opens the ClipSync control popover.
5. The menu bar remains revealed while the popover is open.
6. The control app tests pass after the final rebuild.

If any criterion fails, the icon is not fixed. Do not commit a claimed fix.

## Evidence To Capture

Record these facts for each troubleshooting iteration:

- App build and launch command used.
- Process ID and absolute executable path.
- A full, uncropped desktop screenshot with the revealed menu bar. Do not use
  a screenshot where the menu bar is auto-hidden.
- A screenshot after clicking the status item, showing the ClipSync popover.
- The result of `swift test`.

The screenshot must show the actual macOS status area, not just the application
window or an accessibility tree. A user screenshot that does not show the item
overrides an agent's inference that it exists.

## Troubleshooting Loop

Work through these stages in order. Finish the evidence check for a stage
before moving to the next one.

### 1. Establish A Clean Baseline

1. Stop duplicate ClipSync Control processes.
2. Build and launch only via `macos/ClipSyncControl/script/build_and_run.sh`.
3. Confirm the process runs as the logged-in desktop user and from the expected
   app bundle.
4. Reveal the menu bar and take the required screenshot.

If the item appears, proceed directly to the click and popover checks. If it
does not, continue to stage 2.

### 2. Verify AppKit Status-Item Creation

Add minimal, temporary diagnostics at the `NSStatusItem` creation boundary.
They may report only non-sensitive state such as:

- status item allocated;
- `statusItem.button` exists;
- status item visibility value;
- item frame or length.

Rebuild, relaunch, collect the diagnostics, then repeat the full menu-bar
screenshot. Diagnostics are supporting evidence only; they do not pass the
visual criterion.

### 3. Isolate The Runtime Boundary

When AppKit reports an item but it is missing visually, create a minimal native
`NSStatusItem` control using the same app bundle, launch script, and logged-in
macOS session. Give that control an unmistakable temporary text label.

- If the control is also absent, investigate the launch/session/menu-bar
  environment before modifying ClipSync UI code.
- If the control appears, compare its application lifecycle, status-item
  ownership, image configuration, and status-item length against ClipSync.

### 4. Apply One Narrow Fix

Change only the defect proven by the previous stage. Do not combine an icon
redesign, a settings-window refactor, and a menu-bar lifecycle change in the
same troubleshooting iteration.

After each fix, restart from stage 1 and recapture the required visual evidence.

### 5. Finalize

1. Remove temporary diagnostics and test controls.
2. Run `swift test` and `git diff --check`.
3. Repeat the visible icon and popover checks on the final clean build.
4. Commit and push only when every required pass criterion is satisfied.

## Reporting Rule

Every status update and final report for this issue must say which of the
required pass criteria were actually verified, and must identify any blocked
visual check. Never infer menu-bar visibility from the process being alive.
