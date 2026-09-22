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
- Legend and actual conditions agree: red <125 GiB; orange <300 GiB or growth >=10 GiB; yellow ? for
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
