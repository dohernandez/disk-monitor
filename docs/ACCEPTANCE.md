# Acceptance checks

Use the relevant checks for the change; do not repeatedly perform a full disk scan.
Use a small disposable tracked folder for scan interactions where possible. Record
what passed, what failed, and what was not exercised. Never lower actual free disk
space just to test an alert: use the pure function/model fixture instead.

## Automated baseline

Build then run the binary with `--self-test` as described in
[Development](DEVELOPMENT.md). This checks scanner fixtures, asynchronous collapse,
activity states, free-space boundaries, growth deduplication, partial-root alerts,
cancellation alerts, and timer/preference behavior. It does not prove every manual
check below. For a docs-only edit, verify links and source agreement; no rebuild needed.

## Popup and visual checks

- Launch has an icon only, with native light/dark menu bar tint. No “Disk” title.
- Clicking the drive or its colored badge opens the same popup.
- Outside click, Escape, repeated icon click, and switching apps close it.
- Repeated open/close does not accumulate event monitors or break click handling.
- The popup uses soft charcoal, readable muted text and accents, and a teal header.
  Check scanning labels, partial warnings, settings fields, and buttons for contrast.
- No folder is automatically expanded at fresh launch. Explicit top-five/alert
  navigation may open ancestors; closing/reopening the popup need not reset them.
- Top-five cards show measured candidates, largest first, with no selected ancestor
  alongside a descendant. Clicking the same card twice still navigates correctly.

## Tree and scanning checks

- Footer icons expose Add folder, Scan now/Stop scan, Info, and Settings with tooltips.
  Info returns with Back; settings and existing measurement behavior remain intact.

- Row expansion and its separate scan button do not trigger each other.
- Expand, immediately collapse during loading, and wait: it stays collapsed. Reopen
  works using cached entries. Large directory enumeration does not block the UI.
- Children sort largest first after measurements; unknown sizes follow.
- A small row scan shows activity even when a saved size exists; prior size stays visible.
- A batch shows a spinner for the active root and clocks for waiting roots, also in
  affected descendants/ancestors and top-five cards. Prefix-neighbor paths stay idle.
- No second scan starts while busy. Stop drops the unfinished result, keeps completed
  results, clears queue/activity, and does not itself create a badge warning.
- Missing/unreadable paths are not represented as zero. Partial results show ≥ and
  no delta; an existing complete reading survives a failed scan with its old timestamp.
- Add folder persists across restart; Stop tracking removes the extra root without
  deleting files. Finder/copy-path actions remain functional.

## Settings and alerts

- Current saved values preload. Valid settings apply without restart and survive it.
- Invalid/empty/fractional/out-of-range input does not change timers or saved values.
- Back is bottom right, discards edits; Quit is a footer icon. No duplicate top Back.
- Defaults are 30 seconds and 5 minutes only when there is no valid saved choice.
- Changing intervals replaces both timers; it neither stops nor duplicates a scan.
- Free-space polling alone does not change folder readings. Opening the popup does
  not start a folder scan. Automatic folder ticks skip an existing scan.
- Legend and actual conditions agree: red <10% (configurable); orange <20% (configurable) or growth >=10 GiB; yellow ? for
  incomplete/failed measurements. Red > orange > yellow; no badge means
  no active alert, not guaranteed complete coverage.
- A successful comparable rescan updates growth; low-space alerts update from capacity
  queries. Folder alerts navigate to their row. Unavailable capacity warns.

## Evidence and gaps

During draft development, build and scanner/model self-tests passed, and the user
reviewed successive live versions. The accepted baseline includes the charcoal theme
and loading indicators. This is not an automated end-to-end UI suite. In particular,
self-tests do not cover top-five ranking, save failure, active-process cancellation,
or AppKit event routing. Pure merge protection and legacy Reading decoding now have fixtures.
When changing those areas, add focused coverage or explicitly record manual evidence.

The documentation pass dated 2026-09-18 changes no runtime code or bundle. Existing
compiled-test evidence must not be presented as a fresh build of future edits.

Navigation consistency: Info/Settings retain the footer, hide the large capacity
summary, toggle closed via their own icon, and switch directly via the other icon.
Back returns to the dashboard; leaving Settings without Save discards draft edits.

Partial scan attribution: stderr is parsed under LC_ALL=C. A path-specific du error affects only that path, its ancestors, and descendants; unaffected sibling results are complete. Unrecognized diagnostics conservatively mark the whole scan partial. Complete saved measurements still survive an affected rescan; fresh complete results repair old partial labels without a growth delta. Optional Reading.scanError persists the diagnostic for partial readings (legacy JSON decodes without it). Hover “Partial · scan error” for the cause, or inspect the tracked-root alert. Previously saved partial flags remain until remeasurement; no flags are blindly cleared. Self-tests cover sibling isolation, prefix neighbors, colon paths, global fallback, merge protection and legacy/roundtrip persistence.

Alert categories: red ! for critical free space; orange ! for low free space or large growth; yellow ? for incomplete/failed measurements (including unavailable free-space query). Highest priority wins: red > orange > yellow > none. The same type drives menu badge, per-alert symbol/color and Settings legend. Self-tests cover mixed-alert priority and failed-capacity classification.

## Updates and privacy

- Run `SPARKLE_TOOLS=<build-dir>/sparkle python3 -B scripts/test_signatures.py`.
  Valid signed fixtures pass; changed installers, unsigned/changed feeds and wrong
  keys must fail. PR CI repeats this with temporary keys on both architectures.
- Verify cache migration preserves data, sets owner-only modes and rejects links.
- Manually check Settings update controls, automatic preferences across restart,
  update UI from a menu-bar app, and upgrade/relaunch while a measurement is active.
  Signature unit tests do not establish these interactive behaviors.
- The installed v1.0.0 app needs a manual upgrade before it can use in-app updates.

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

## Spotlight index tracking

- Fixture tests cover absent/present index paths, largest-folder eligibility and
  persisted exclusions without deleting saved readings. Real Spotlight is not scanned.
- Verify the Settings toggle and Shared caches & tools row on a Mac with an index.
- Root-only access must stay protected/partial, never zero; do not grant privileges
  or rebuild the index as an acceptance shortcut.
- Native toggle/click behavior and successful administrator-owned index measurement
  remain manual checks; the app installs no persistent privileged helper.

## Integrated protected-folder scanner (pending release acceptance)

- Default builds must report unavailable and cannot register an unsigned/missing helper.
- Signed app/helper mismatch, wrong peer, modified code and arbitrary paths fail closed.
- Tests never register a daemon, request credentials or scan the real Spotlight index.
- With accepted packaging, verify setup, explicit consent, scheduled opt-in, row refresh,
  Stop, saved result timestamps, cooldown and retry after setup failure.
- Verify no parallel ordinary/privileged scan; late/cancelled results cannot overwrite
  saved readings. Disconnect after measure must not pretend the scan has exited.
- Repeat update repair, restart and disable on both architectures before release.

September 24 preview evidence (build 7, arm64): the user observed a running scan
followed by “Measurement cancelled”, then disabled the scanner. After disabling,
the registered service and fixed-path du process were absent. This confirms visible
cancellation feedback and final cleanup, not the precise child-exit timing before
unregister or acceptance of the new nested-host integration. Intentional cancellation
now has its own heading in source; no replacement preview was installed.

## Deleted growth candidates

Free-space refresh and completed scan batches asynchronously check saved growth
candidates with metadata-only lstat calls. ENOENT/ENOTDIR confirms absence;
permission and I/O failures do not. Confirmed absent paths stop producing growth
alerts and leave the largest-folder ranking. Their saved bytes/date remain; an
optional `missing` field persists this state and the old comparison is cleared.
A successful scan of a recreated folder establishes a new baseline before growth
can be reported again. Legacy readings decode without the optional field. A late
validation result cannot overwrite a newer reading. No monitored file is changed.
Fixture checks cover deletion, retained history, restart, recreation and error
classification; live UI behavior remains a separate manual acceptance check.

## General protected-folder guidance

- Info shows Folders protected by macOS for all tracked-folder types, not just Spotlight.
- Scroll the full text at normal popup size; Back and footer remain reachable.
- Wording distinguishes partial, protected and historical readings, broad Full Disk
  Access, background approval and launch failure without promising universal access.
- Opening Info performs no authorization, registration or scan. Added folders cannot
  invoke the Spotlight-only administrator operation.
