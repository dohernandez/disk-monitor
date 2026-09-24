# Disk Monitor usage guide

[Back to overview](../README.md) · [Development and recovery](DEVELOPMENT.md)

## Using the dashboard

The header shows free space on the filesystem containing your home directory.
The configurable largest-folder list ranks measured projects, worktree repositories, and cache folders.
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
| Red | Less than **10% (configurable)** free |
| Orange ! | Less than **20% (configurable)** free, or folder growth of **10 GiB or more** between comparable scans |
| Yellow ? | Incomplete/failed tracked-root measurement or unavailable free-space reading |
| No badge | No active alerts in the available readings |

Red takes priority over orange, then yellow. Failed free-space queries show yellow ?. At exactly the critical threshold the
space warning is orange; at exactly the warning threshold there is no space warning. Click the
icon for the reasons. These are visual alerts, not macOS notification banners.
Cancellation alone does not raise an alert. Growth changes only after folder scans;
it compares the latest comparable measurements, not a fixed time window.

## What is tracked

Paths are relative to your home directory:

| Row | Path |
|---|---|
| Folders | User-selected paths (existing saved labels are preserved) |
| Library caches | `~/Library/Caches` |
| Go modules | `~/go/pkg/mod` |
| Cargo | `~/.cargo` |
| Rust toolchains | `~/.rustup` |
| Anvil temporary files | `~/.foundry/anvil/tmp` |
| Claude session history | `~/.claude/projects` |
| Docker VM storage | `~/Library/Containers/com.docker.docker/Data/vms` |

Use **Add folders…** to select roots or deep folders needing scheduled measurements.
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

Known limitations include stale cached paths, limited scan-error persistence, and no
schema migration or backup system. The bundle declares macOS 13, but the build does
not explicitly target it and the UI uses newer APIs. Do not claim macOS 13 support.
See [Architecture](ARCHITECTURE.md) for details.

## Navigation and partial scans

Info and Settings use a compact title header and retain the dashboard footer.
Clicking either icon again returns to the dashboard; switching icons goes directly
to the other page. Back stays fixed above the footer on the right and discards
unsaved settings edits. Quit is the footer’s rightmost power icon.

Path-specific scan errors affect that path, its ancestors, and descendants;
unaffected siblings can still have complete readings. Unrecognized diagnostics
conservatively mark the whole scan partial. A fresh complete measurement repairs
an old partial label without inventing a growth delta. Previously saved partial
flags remain until remeasurement; they are not blindly cleared. Hover
**Partial · scan error** for the cause, or inspect the tracked-root alert.

See [Architecture](ARCHITECTURE.md) for parser behavior, persistence, and known gaps,
and [Development](DEVELOPMENT.md) for missing-icon diagnosis.

Permission-only scans: confirmed `du` permission denials show “Protected by macOS”
(or “Partial · protected contents” when a lower-bound size is available). They do
not trigger the menu-bar ? badge. Mixed, unknown and other scan failures still warn;
free-space and growth thresholds are unchanged. Classification uses all diagnostics
before display truncation. Legacy partial readings require a fresh scan before
suppressing their warning. No filesystem permissions are changed.

## Portable tracked folders

Fresh installations detect existing common cache directories and ask the user to
choose a Projects folder. A legacy saved YeagerAI Projects reading is preserved
as the project root; new installations do not assume that layout. Changing Projects
replaces the root without deleting measurements. Right-click any tracked root to
stop tracking; exclusions persist across restarts and Add folder can restore a root.
Stopped roots no longer contribute to scans, alerts or rankings unless covered by
another tracked ancestor. Manually added missing folders remain visible as Not found;
saved sizes are explicitly labelled when their folder is missing.

Saved JSON adds optional projectPath and excludedPaths fields. Old JSON decodes
without them; older app versions ignore them (and may show default folders again).
No files are deleted and no preferences or permissions reset. Regression fixtures
cover an empty/default home, selection, duplicate prevention, missing custom paths,
restart persistence, legacy migration and removal from alerts/rankings.

## Folder settings

Settings → Tracked folders configures the largest-folder count (1–50, default 5),
multiple project roots with editable labels, detected default-cache toggles and
custom cache roots. These controls save immediately, separately from refresh
interval edits. Project labels save with Rename or Return. Remove stops tracking
without deleting measurements or files. The top list ranks measured children across
all project roots, worktree children, Library cache children and configured cache/extra
roots, suppressing overlapping parent/child entries as before.

Optional saved fields projects, customCaches and largestCount preserve old JSON
compatibility. With projects absent, the old projectPath or legacy saved YeagerAI
root remains active; an explicitly empty projects array means no project roots.
Existing readings, extras, exclusions and intervals are preserved. Older app versions
ignore the new fields and cannot reproduce multiple-root/count settings on rollback.
Fixture checks cover migration, multiple roots, label/count persistence, boundaries,
custom caches, duplicate prevention and ranking across roots. Native folder-picker
and Rename/Remove click behavior still require manual acceptance.

In Settings, Free disk space and Folder sizes stay together at the top, followed
by their Save settings button. Tracked folders appears below these refresh controls.

Settings → Free-space alerts accepts whole percentages with 1 ≤ red < orange ≤ 100.
Defaults are 10% and 20%. Save alert thresholds applies both immediately and
persists them across restarts; Back discards unsaved threshold edits. The preview
and legend show each percentage’s equivalent storage using the monitored volume.
Upgrading replaces the old fixed 125/300 GiB limits with these percentage defaults.
Folder growth remains an independent 10 GiB threshold.

## Folder labels in Settings

Under Tracked folders, **Folders → Add folders…** accepts source directories,
agent workspaces and other folders. The same Add folders… action is available
on the dashboard. **Caches & tools** remains separate. Existing folder labels,
paths, saved measurements and ranking behavior are unchanged.

## Spotlight index tracking

Shared caches & tools includes Spotlight index when
`/System/Volumes/Data/.Spotlight-V100` exists or has a saved reading. Its Settings
checkbox enables/disables tracking like other detected caches; disabling keeps saved
measurements. The path is injectable for fixture tests; tests never scan the real index.

Scans use the existing serial, cancellable directory scanner. Root ownership can
prevent measurement even with Full Disk Access. Permission-only failures display
Protected by macOS (or a partial lower bound), not zero, and do not raise the
measurement-warning badge. The optional scanner integration is described below; ordinary scans never escalate. Previously complete readings remain saved on failure. A full
index scan can be expensive because it may contain millions of files.

The Nix store row remains informational: Separate accounting means the app does
not measure it yet. APFS volume usage can be measured independently, but is not a
Nix garbage-collection/reclaimable-space estimate.

## Protected-folder scanner integration (not released)

The working branch replaces the failed AppleScript authorization path with an
optional, fixed-target scanner. Ordinary builds do not bundle or authorize this
helper; setup explicitly reports when the signed package is unavailable.

A scanner-enabled build offers **Protected-folder setup…** on the Spotlight row.
Setup validates the app/helper signatures before registration. Enable is an
explicit user action; scheduled scans never register, authorize or open settings.
After background approval and Full Disk Access as needed, use the row refresh to
verify and measure. Scheduled Spotlight measurement is a separate opt-in toggle.
Other tracked folders continue to use the ordinary unprivileged scanner.

After a launch failure, Repair guides: unregister; turn OFF only this app's
background approval in Login Items & Extensions; register; turn approval ON; verify.
This sequence recovered the build 6 → 7 prototype on the test Mac without changing
Full Disk Access. It is not a guarantee for every update. Never reset unrelated
background items or grant a shared shell Full Disk Access.

The helper accepts only authenticated, argument-free ping, fixed Spotlight measure
and own-measurement cancellation. It cannot scan arbitrary added paths. The app
serializes this request with ordinary folder scans, retains complete saved readings
on failure, and saves the helper's actual timestamp on success. Cooldown responses
retain their original date; they are not new measurements. A visible 60-second
countdown explains the minimum interval. Administrator summaries do not generate
cross-method growth deltas.

Stop requests cancellation of the owned scan. A lost connection does not prove
termination. The app saves the boot identifier before requesting measurement and
blocks new scans and updater relaunch until completion is confirmed or the Mac
restarts. Reopening the app preserves that block. Setup explains recovery and offers
Quit; quitting alone is not scanner unregistration or proof the scan stopped.
Crash/reboot recovery still requires live acceptance before release.

Release signing, installer compatibility, clean-Mac setup, cancellation and restart
acceptance remain required. No release workflow activates this integration yet.

## Folders protected by macOS

Info contains shared guidance for every tracked folder, including custom roots and
caches. Permission-only failures are not empty folders. Full Disk Access can be
reviewed in System Settings → Privacy & Security; reopen Disk Monitor after changing
it and refresh the affected folder. This broad permission does not override every
system ownership restriction. Background approval, Full Disk Access and administrator
authorization are distinct; a helper launch failure must not be described as missing
disk access. Adding a folder does not authorize administrator measurement.

The general guidance does not extend the Spotlight-only administrator operation to
other paths. Future protected-folder support requires separate validation. The
automatic scanner remains an isolated prototype, not a shipped feature.
