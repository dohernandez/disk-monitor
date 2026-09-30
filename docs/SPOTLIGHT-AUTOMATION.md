# Spotlight exclusion controls — implementation and validation

This candidate replaces suggestion management with an ordinary app window and
real Search Privacy add/remove operations via the public Accessibility API.
It does not write Spotlight plists, rename folders, install a separate app, or
change scanner permissions. Accessibility is requested only by the explicit button.

## Existing implementation used as a reference

- [Apple UI automation guide](https://developer.apple.com/library/archive/documentation/LanguagesUtilities/Conceptual/MacAutomationScriptingGuide/AutomatetheUserInterface.html)
- [technicalpickles addition script](https://github.com/technicalpickles/dotfiles/blob/5b32cbe0c4a7c52d2dc3e2925471bfc5d2914343/bin/spotlight-add-exclusion)
- [Accepted implementation decision](https://github.com/technicalpickles/dotfiles/blob/5b32cbe0c4a7c52d2dc3e2925471bfc5d2914343/doc/adr/0010-manage-spotlight-exclusions-with-applescript.md)

The reference documents Sequoia navigation: Spotlight extension, Search Privacy
sheet, Add, nested folder chooser, Go to Folder. This implementation uses native
AX calls rather than copied script code. It does not inherit unconditional success
counts, quitting System Settings, treating read failures as an empty list, or sudo.

## Verification contract

Read the complete AX row collection and require exactly one absolute file path
identity for every row. Display Unknown if the list or any identity cannot be read.
Never select a deletion target by its basename. Before Remove, replace and verify
the selected-row set contains only the exact target. Before Add, require exact
identities for every selected chooser element; the chooser current-directory URL
is not accepted as proof of selection. Parent exclusions disable child
removal: removing a parent could affect other monitored and unmonitored folders.
After a mutation, require the exact expected list, close the sheet, reopen it and
verify the persisted result. Focus loss, cancellation, ambiguity or timeout stops
the sequence and makes state unknown; a mutation may already have occurred, so a
failure is not reported as a rollback. No background retries or automatic changes.

The window stays open when Settings becomes active. One serial worker operates the
UI; AX messaging and stage waits are bounded. Closing the window requests stopping
at the next check. Existing scanner/permissions logic is unchanged.

## Test mode for live validation

`DiskMonitor --spotlight-exclusion-test` is a development-only launch that opens
just the exclusion window. It is checked before any other launch mode and never
reaches normal startup: no status item, updater, scanner registration, scans or
timers. Preferences use a unique temporary suite and readings a temporary folder;
both are removed on quit. Candidates are disposable fixtures in
`$TMPDIR/DiskMonitor-exclusion-fixtures` (duplicate `Cache` basenames, spaces,
Unicode, and `excluded-parent/child`). Checkboxes for folders outside that
location, including real exclusions, are refused before any Accessibility call.
Fixture folders are kept between runs so a leftover exclusion can be removed
next time. Quitting mid-operation can leave the Settings sheet open; refresh on
the next run. Accessibility is still granted to the tested build by the user.

Add `--run-scenarios` to run the live checks headlessly through the same verified
automation: read, add/remove with spaces, one of two duplicate `Cache` basenames,
Unicode, parent coverage (child add is a no-op, child removal is blocked), then
restore. Any fixture left excluded is removed and the final list must equal the
initial list. Results go to `$TMPDIR/DiskMonitor-exclusion-results.log`; the app
quits when done. Without Accessibility it records the denial and changes nothing.
Launch with `open -n` so macOS attributes Accessibility to the test build itself,
not to the terminal that started it. The permission row is keyed to the app ID and
its signature: an ad-hoc test build does not match a row created for a
certificate-signed build, so that row must be removed before the test build can
register its own.

## Release gate: live validation still required

This is an unverified automation candidate, not a demonstrated working integration.
Internet documentation establishes a reference for navigation, not the current
AX hierarchy or exact path availability. Some systems may expose names without
paths; those systems deliberately get Unknown. Initial control labels are English;
other layouts/languages must fail without guessing rather than claim support.

Before release, on macOS 15 and newer supported versions: grant Accessibility to
Disk Monitor; use disposable folders (including duplicate basenames, spaces,
Unicode and a child of an excluded parent); verify refresh, add, persisted read,
remove, denial, Settings focus loss, cancellation and unrelated open dialogs.
Confirm no other entry changes and no real cache folders are modified by tests.
The agent's Computer Use tool currently lacks permission, so this validation cannot
be claimed from fixture tests or successful compilation.

## Exact state from the root scanner (option A, Darien 2026-09-30)

Live tests on macOS 15.7.4 and 15.7.7 showed Search Privacy rows expose only folder names.
`mdutil -P` and `VolumeConfiguration.plist` need root. Checkboxes therefore come from the
root scanner's read-only `exclusions` operation (see HelperPrototype/SECURITY.md). Reading
needs no Accessibility and never opens System Settings. Changes still go through Search
Privacy, and each one is confirmed by the root list: add expects before plus path, remove
expects before minus path. Removal selects the row by name only when that name is unique
among excluded folders; otherwise it refuses and points to System Settings. When the scanner
is off or unavailable, the window still adds folders, verified by the new row's name, and
shows the state as unknown.

The folder chooser runs in a separate process: keys go to the frontmost app (as System
Events does), only while System Settings is frontmost. It supports list, icon and column
views ([openpath #64](https://github.com/TamaT-LLC/openpath/pull/64)) and confirms with the
`OKButton` identifier ([Peekaboo](https://github.com/steipete/Peekaboo)). Paths are
compared in NFC form, because the chooser reports decomposed names.

Live runs happen only in the disposable Tart VM (`taskfiles/vm/scripts/vm-run.sh`), never on
a real Mac. Result on 2026-09-30, macOS 15.7.7 en_US: 12/12 scenarios passed, covering read,
add/remove with spaces, one of two duplicate basenames, Unicode, parent coverage and
blocked child removal, and a final list equal to the initial one. The test build reads the
list through `sudo -n` in the VM, and the scanner's own reader is covered by its fixtures;
the end-to-end scanner registration path is not yet exercised in the VM.
