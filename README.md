# Disk Monitor — draft 01

A native macOS menu bar app for seeing free disk space, large development folders,
and growth between scans. Click the drive icon to open the dashboard. It runs locally,
with no network service, telemetry, cleanup actions, or login item.

## Start here

- [Agent maintenance rules](AGENTS.md): read before changing the app.
- [Architecture and data](docs/ARCHITECTURE.md): source map, scanning, timers, storage, and limitations.
- [Development and recovery](docs/DEVELOPMENT.md): build, checks, safe replacement, and rollback.
- [Acceptance checklist](docs/ACCEPTANCE.md): behaviors to preserve when making changes.

## Build and open

Requires macOS, Apple Command Line Tools with Swift, and Python 3.

```sh
./build.sh
"build/Disk Monitor.app/Contents/MacOS/DiskMonitor" --self-test
open "build/Disk Monitor.app" --args --show
```

If the app is already running, follow the replacement procedure in
[Development](docs/DEVELOPMENT.md) first. The build overwrites the local bundle.
This is a local, ad-hoc signed draft, not a notarized distribution. Older macOS
compatibility is not established; see the deployment-target limitation below.

## Using the dashboard

The header shows free space on the filesystem containing your home directory.
The top five ranks measured projects, worktree repositories, and cache folders.
Click a ranked folder or folder alert to reveal it in the expandable tree.
This is a ranking of tracked candidates, not a whole-disk search.

- Folder rows expand or collapse. Children are sorted by measured size, largest first;
  unmeasured children follow. All rows start collapsed on launch.
- The **refresh arrow (Scan now)** measures existing tracked roots sequentially. A row's refresh button
  measures that folder. the **stop-circle (Stop scan)** discards the unfinished result and keeps completed readings.
- Spinners identify active folders; clocks identify folders waiting in the current batch.
  Previous sizes stay visible until a measurement completes.
- The **folder-plus icon (Add folder)** adds a tracked root. Right-click a row to scan, copy its path, or show
  it in Finder. Added roots also offer **Stop tracking**; this never deletes the folder.
- The info icon explains measurements. The gear opens settings and the alert legend. **Back** discards unsaved edits;
  **Save settings** applies them. **Quit Disk Monitor** is the power icon in the footer.
- Click outside the popup, press Escape, or click its menu bar icon again to close it.

## Refresh and resource use

| Setting | Default | Allowed values | Work performed |
|---|---|---|---|
| Free disk space | 30 seconds | 5–3,600 seconds | Filesystem capacity query; no directory walk |
| Folder sizes | 5 minutes | 1–1,440 minutes | Recursive `du`, one tracked root at a time |

Settings persist across restarts. Existing saved choices take precedence over defaults.
Opening the popup refreshes free space, not folder sizes. Launch scans roots with
missing or old readings. An automatic tick during a scan is skipped; scans do not overlap.
Saving intervals replaces both timers without interrupting an active scan.

Folder scans can take seconds or minutes and create disk I/O; cost depends on file
count and filesystem load. No fixed CPU/memory or duration guarantee has been measured.
Top-five rankings and alerts use cached readings and do not trigger extra scans.

## Alert legend

| Badge | Meaning |
|---|---|
| Red | Less than **125 GiB** free |
| Orange ! | Less than **300 GiB** free, or folder growth of **10 GiB or more** between comparable scans |
| Yellow ? | Incomplete/failed tracked-root measurement or unavailable free-space reading |
| No badge | No active alerts in the available readings |

Red takes priority over orange, then yellow. Failed free-space queries show yellow ?. At exactly 125 GiB the
space warning is orange; at exactly 300 GiB there is no space warning. Click the
icon for the reasons. These are visual alerts, not macOS notification banners.
Cancellation alone does not raise an alert. Growth changes only after folder scans;
it compares the latest comparable measurements, not a fixed time window.

## What is tracked

Paths are relative to your home directory:

| Row | Path |
|---|---|
| Projects · YeagerAI | `~/Documents/YeagerAI` (including its `worktree/` tree) |
| Library caches | `~/Library/Caches` |
| Go modules | `~/go/pkg/mod` |
| Cargo | `~/.cargo` |
| Rust toolchains | `~/.rustup` |
| Anvil temporary files | `~/.foundry/anvil/tmp` |
| Claude session history | `~/.claude/projects` |
| Docker VM storage | `~/Library/Containers/com.docker.docker/Data/vms` |

The project root is currently specific to this machine's layout. Use **Add folder**
for other roots or for deep folders needing their own scheduled measurements.
Nix is an informational row only; Nix reclamation and Docker-internal accounting
are not implemented.

## Reading sizes correctly

`du -k -d 2` recursively measures a root but reports only two levels beneath it.
Expand further and scan a row for deeper readings. The tree lists directories only;
folder totals also include files. Hidden directories are included; symlink directories
are not expanded. Sizes use binary formatting, although the formatter displays labels
such as GB rather than GiB.

Folders may overlap or share APFS storage. Do not sum rows or treat their sizes as
space guaranteed to be reclaimable. Free space and folder totals are different measurements.
A failed scan keeps an existing complete reading. Without a complete reading, partial
results show **≥** and have no growth comparison. Hover a size to see its measurement time.
Protected folders may be unreadable; permission failures are not zero-byte results.
The app does not request Accessibility or Screen Recording permission.

Readings and added roots live in
`~/Library/Application Support/DiskMonitor/readings.json`; intervals use UserDefaults.
The popup intentionally uses a soft charcoal theme. Its drive icon follows the native
menu bar tint, with a separate colored warning badge.

Known draft gaps include stale cached paths, limited scan-error persistence, and no
schema migration or backup system. The bundle declares macOS 13, but the build does
not explicitly target it and the UI uses newer APIs. Do not claim macOS 13 support.
See [Architecture](docs/ARCHITECTURE.md) for details.

The compact footer places status and measurement time on the left, and folder-plus,
refresh/stop, info, and settings icons on the right. Each icon has a tooltip and
accessibility label. Refresh still scans folders; it is not a separate capacity button.

Info and Settings use a compact title header and retain the dashboard footer.
Clicking either icon again returns to the dashboard; switching icons goes directly
to the other view. Both pages offer a Quit footer icon and Back fixed above the footer on the right.

Quit is the rightmost power icon in the persistent footer. On Info and Settings,
Back stays fixed immediately above that footer, right-aligned, outside scrolling
content. Leaving Settings with Back discards unsaved edits.

Partial scan attribution: stderr is parsed under LC_ALL=C. A path-specific du error affects only that path, its ancestors, and descendants; unaffected sibling results are complete. Unrecognized diagnostics conservatively mark the whole scan partial. Complete saved measurements still survive an affected rescan; fresh complete results repair old partial labels without a growth delta. Optional Reading.scanError persists the diagnostic for partial readings (legacy JSON decodes without it). Hover “Partial · scan error” for the cause, or inspect the tracked-root alert. Previously saved partial flags remain until remeasurement; no flags are blindly cleared. Self-tests cover sibling isolation, prefix neighbors, colon paths, global fallback, merge protection and legacy/roundtrip persistence.

AppDelegate must stay strongly retained across the complete NSApplication.run() call using withExtendedLifetime. NSApplication.delegate is weak; losing the delegate also loses its NSStatusItem and can leave an iconless process running. Preserve this lifetime guard in both optimized and debug builds.

Launch with --diagnostics to record startup and status-item geometry in /tmp/DiskMonitor-launch-diagnostic.jsonl. isVisible does not prove unobscured placement; compare the frame with NSScreen.auxiliaryTopRightArea. Diagnostic logging is off normally.

Each status item has a stable app-specific autosaveName. Its own NSStatusItem Preferred Position preference is seeded to 0 only when absent, to start at the right end rather than behind the notch. Subsequent user placement is preserved. This AppKit preference is not a public positioning API and needs rechecking on OS upgrades; precedent: https://github.com/jordanbaird/Ice/blob/main/Ice/MenuBar/ControlItem/ControlItem.swift . Other apps and global preferences are untouched.
