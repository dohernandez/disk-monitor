# Architecture and data

Stable baseline: version 1.0.0, 2026-09-22. Measurement/runtime code is in
[`main.swift`](../main.swift), with updates in [`Updates.swift`](../Updates.swift);
packaging is in [`build.sh`](../build.sh).
Use symbol names below to navigate, since line numbers change.

## Source map

| Symbol | Responsibility |
|---|---|
| `Palette`, `sizeText`, `intervalText` | Theme and formatting |
| `Reading`, `Root`, `Saved` | Codable persisted data |
| `DiskAlert`, `diskSpaceAlert` | Alert representation and free-space thresholds |
| `Scanner`, `ScanResult` | Owned `du` process, parsing, cancellation |
| `Model` | Published state, timers, serial scan batch, directory cache, ranking, persistence |
| `ScanActivityIndicator`, `FolderRow` | Tree and per-path activity |
| `LargestFolders`, `AlertPanel` | Cached rankings and attention panel |
| `RefreshSettings`, `Dashboard` | Settings and 440 × 690 point popup |
| `StatusBadgeView`, `AppDelegate` | AppKit status item, badge, popup lifecycle |
| `--self-test` branch | Fixture scanner/model regression checks |

`Updates.swift` owns Sparkle startup, preferences and the Settings update controls.

## Lifecycle and threads

The normal entry point creates NSApplication and AppDelegate. Model initialization
loads preferences and saved readings, queries filesystem capacity, and schedules
both timers on the main run loop in common mode. AppDelegate creates an accessory
app (no Dock icon), status item, and transient NSPopover hosting the SwiftUI dashboard.
After 0.6 seconds it calls `scanMissingRoots`. `--show` additionally opens the popup.

Model owns observable state. The UI and timer callbacks call it on the main thread.
`scan` sets its busy flag before dispatching one serial root loop to a utility queue.
The loop announces each active path on the main queue, calls Scanner, then applies
results with `DispatchQueue.main.sync`. Final cleanup clears activity and refreshes
capacity. Do not move that synchronous dispatch into a main-thread caller.

`loadChildren` separately enumerates directory entries on a utility queue and publishes
its result on the main queue. Expansion state belongs only to `toggle` and `reveal`;
read completion does not change it. Scans invalidate directory caches beneath the
scanned root and reload expanded directories. `revealRequest` changes even when the
same path is selected twice so repeat navigation works.

AppDelegate installs local/global mouse monitors only while the popup is shown.
Escape, outside clicks, deactivation, and icon toggle close it. Closing removes
monitors; termination also cancels the scanner. The popup is forced dark via both
NSAppearance and SwiftUI color scheme; this does not force the menu bar appearance.
The template drive icon uses AppKit tint. A separate 13-point yellow/orange/red badge has
`hitTest` returning nil, so clicking it still activates the status button.

## Measurement pipeline

`Scanner.scan` invokes `/usr/bin/du` with separate arguments `-k -d 2 <path>`.
There is no shell interpolation. It drains stdout through a pipe and directs stderr
to a disposable file to avoid blocking on a full error pipe. It waits for exit,
parses the first tab on each output line, and multiplies KiB by 1,024.
A nonzero exit returns available values plus path-scoped errors (display excerpts up to 600 characters).
Cancellation discards all values from the unfinished process.

Depth 2 limits output, not traversal: totals still require walking all contents.
Each batch is serial and excludes nonexistent roots. While busy, additional scan
requests return immediately; periodic ticks are skipped. Stop cancels the active
process and prevents the remaining roots from starting. Earlier completed roots
remain saved. This is not a persistent task queue.

When applying results:

- An incomplete result cannot overwrite an existing complete reading.
- A new incomplete result stores a lower bound with `incomplete=true`, no `previous`.
- A successful result records the old byte count only if the old result was complete.
- Known path errors affect that path, ancestors and descendants, not siblings; unrecognized errors apply to the full scan. Partial readings retain scanError and their own dates.
- Results save after each root. The footer's latest time is batch progress, not proof
  that every visible path was measured at that time.

`refreshCapacity` calls FileManager's filesystem attributes for the home directory.
It does not run `du` or shell `df`. Failure sets capacity to zero and produces an alert;
the previous free number may remain in the header (a known limitation).

## Timers and rankings

`diskRefreshSeconds` defaults to 30 (range 5–3,600).
`folderRefreshSeconds` defaults to 300 (range 60–86,400); the UI accepts minutes.
`scheduleTimers` invalidates both previous timers. `configureIntervals` validates
before saving and rescheduling. Timers use weak model captures. There is no sleep/wake
scheduler or exact wall-clock guarantee. Opening the popup queries capacity only.

`largestFolders` selects measured direct children of Projects (excluding the worktree
container), direct children of Projects/worktree and Library/Caches, other default
cache roots, and added roots. It sorts by bytes descending, path for ties, suppresses
ancestor/descendant overlap, and takes five. Partial readings are eligible and labeled.
It is not the globally largest five paths. `children` sorts by bytes, unknown sizes
last, then natural title order. Neither calculation starts a scan.

`alerts` combines free-space status, incomplete/failed tracked-root scans, and >=10 GiB
growth in complete cached readings. Growth candidates are sorted by delta and
ancestor/descendant duplicates suppressed. A fresh successful scan may clear a growth
alert if the new pair no longer crosses the threshold. There is no acknowledgement,
hysteresis, notification, or time-series history. Errors from manually scanned nested
rows appear in that row, but the scan-warning badge loop covers tracked roots only.

## Persistent state

| Storage | Data |
|---|---|
| `~/Library/Application Support/DiskMonitor/readings.json` | `Saved`: `readings` dictionary keyed by absolute path; `extras` array |
| App UserDefaults, bundle ID `local.darien.diskmonitor` | `diskRefreshSeconds`, `folderRefreshSeconds` as integers |
| Memory only | Expanded rows, directory cache, latest failed-scan errors, queue, selected reveal, settings edits |

Each Reading has `bytes: Int64`, optional `previous: Int64`, `date: Date`, and optional
`incomplete: Bool` and optional `scanError: String`. Root has `path` and `title`; its identity is the path. JSON uses
Foundation's default Codable Date representation (seconds since the reference date,
not an ISO string). Absence of `incomplete` is treated as a complete legacy reading.
Writes are atomic, but there is no schema version, backup, or migration framework.
Read/decode failures are silently ignored through `try?`; save failures set footer status. Never rely on that
behavior as a safe migration strategy. Preserve a backup before changing the format.

## Known boundaries and follow-ups

These are documented limitations, not authorization to change the accepted behavior:

- No pruning of stale readings for deleted paths or stopped-tracking roots. Old
  readings may remain in rankings or growth alerts. Growth has only one previous value.
- Partial reading diagnostics persist in scanError. A
  failed rescan retaining a complete result can still lose its new error indication on restart.
- Deeper directory readings are not refreshed by an ancestor's depth-2 output. Scan
  the deeper row or add it as a tracked root. Overlapping roots may repeat traversal.
- No scan timeout, resource budget, bounded stdout buffer, or exclusion list. `du`
  output is buffered in memory. The scanner assumes tab/newline-delimited paths;
  filenames containing newlines are not robustly handled.
- Physical reclamation cannot be inferred by summing APFS clones, overlapping paths,
  or separately scanned hardlinks. Nix has no scanner; Docker reports host files only.
- Protected-folder access can fail. There is no Full Disk Access onboarding flow.
- Top-five, save-failure, popup events, and visual contrast
  lack dedicated automated coverage. Self-tests do not constitute full UI validation.
- Version 1.0.0 sets both bundle metadata and the Swift deployment target to macOS 15.
  Native arm64 and x86_64 builds are validated separately by CI.
- CI packages signed updates and DMGs; there is no launch-at-login, notarization, or multi-volume UI.

Partial scan attribution: stderr is parsed under LC_ALL=C. A path-specific du error affects only that path, its ancestors, and descendants; unaffected sibling results are complete. Unrecognized diagnostics conservatively mark the whole scan partial. Complete saved measurements still survive an affected rescan; fresh complete results repair old partial labels without a growth delta. Optional Reading.scanError persists the diagnostic for partial readings (legacy JSON decodes without it). Hover “Partial · scan error” for the cause, or inspect the tracked-root alert. Previously saved partial flags remain until remeasurement; no flags are blindly cleared. Self-tests cover sibling isolation, prefix neighbors, colon paths, global fallback, merge protection and legacy/roundtrip persistence.

Alert categories: red ! for critical free space; orange ! for low free space or large growth; yellow ? for incomplete/failed measurements (including unavailable free-space query). Highest priority wins: red > orange > yellow > none. The same type drives menu badge, per-alert symbol/color and Settings legend. Self-tests cover mixed-alert priority and failed-capacity classification.

Menu bar recovery: AppDelegate is retained across app.run. DiskMonitor-status is the stable autosaveName; its own preferred-position key is seeded to 0 only when absent. The September 21 missing-icon incident was resolved by repositioning away from the notch, confirmed by the user; the lifetime guard alone did not resolve it. Launch --diagnostics logs startup and item geometry to /tmp/DiskMonitor-launch-diagnostic.jsonl. Match PID/time and compare frame to NSScreen.auxiliaryTopRightArea; isVisible alone is insufficient. Command-drag preserves the user’s chosen position. Do not reset global preferences or other apps.

## Update and local-state security

`Updates.swift` owns one Sparkle controller, started only by AppDelegate. It binds
Settings directly to Sparkle's KVO preferences. Measurement timers are independent.
The updater delegate postpones requested relaunches while measurements are active.
The framework uses the public key and verification requirements in Info.plist; see
[Releasing](RELEASING.md#signed-in-app-updates) for signing, hosting and trust boundaries.

State directories use 0700 and files use 0600, including migration of existing files.
Final state paths reject symbolic links; private files also reject hard links and
unexpected ownership. Parent Application Support permissions are not changed.
This protects against other local users, not another process already running as the
same user or an administrator. Diagnostic subprocess error files are created at 0600.

`PrivateReadings` tightens directory/file modes on load and writes through an
exclusively created 0600 temporary file followed by atomic rename. Save failures
are visible in the footer. Self-test Model instances use temporary state URLs.

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

## Percentage free-space alerts

SpaceThresholds defaults to 10% critical and 20% warning of the monitored home
volume's capacity. Whole-number settings require 1 ≤ critical < warning ≤ 100.
UserDefaults keys criticalFreePercent and warningFreePercent persist the pair;
invalid saved pairs fall back together to defaults. Existing installations adopt
these defaults instead of the old fixed-byte thresholds. Readings and intervals
are unchanged. Save alert thresholds applies immediately, including the menu badge.
The settings preview and saved legend show equivalent binary-formatted storage;
unknown capacity shows unavailable, never a fabricated zero threshold. Folder
growth remains 10 GiB and measurement-warning priority is unchanged.
