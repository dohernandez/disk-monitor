# Maintaining Disk Monitor

This directory is a standalone macOS app, not part of genlayer-node. Read
[README.md](README.md), [Architecture](docs/ARCHITECTURE.md), and the relevant
[Acceptance checks](docs/ACCEPTANCE.md) before editing. Source and tests are the
implementation truth; document disagreements rather than silently broadening scope.

## Scope and workflow

- Make the requested change only. Preserve the accepted draft's behavior and user data.
- Inspect current files before editing; another session may have changed them.
- `main.swift` owns the app, model, scanner, and self-tests. `build.sh` packages it.
  `build/` is generated. Do not hand-patch the binary or system toolchain.
- Follow [Development](docs/DEVELOPMENT.md) for build/test/restart/rollback. A build
  overwrites the local app bundle; preserve a working copy first for runtime changes.
- Documentation-only changes do not need a rebuild, restart, or disk scan.
- Do not use broad process kills. Quit through Settings, or verify an exact process
  and its children before stopping it. Never terminate other agents' build/scan jobs.
- No cleanup, pruning, login item, permissions changes, network service, or installer
  is authorized merely by maintaining this monitor.
- Use fixture scans for tests. Do not repeatedly scan Projects, Library, or Nix to
  validate a small edit. Do not invoke desktop automation just for visual QA: it
  previously opened an unwanted ChatGPT Computer Use permissions screen.
- Update these docs when intentional behavior changes. Report what was actually
  verified; successful self-tests do not prove popup appearance or mouse behavior.

## Invariants to preserve

1. **One scan at a time.** Expensive work runs off the main thread. Published UI
   state is applied on the main thread; cancellation affects only the owned `du` process.
2. **Two independent timers.** Free-space checks do not walk directories. Folder
   refreshes skip busy ticks. Changing intervals invalidates old timers and preserves
   an active scan. Keep saved user values; do not reset them to defaults on upgrade.
3. **Honest measurements.** Errors are not zero. Partial results cannot replace
   complete readings. Partial readings have no growth delta. Cancelled results are
   discarded. Never sum overlapping/APFS-shared folders into physical disk usage.
4. **Responsive tree.** Directory enumeration is asynchronous and cached, never in
   SwiftUI rendering. Completion must not reopen a folder the user collapsed.
   Children sort largest first. Launch starts collapsed; explicit reveal may expand.
5. **Visible activity.** Cached sizes remain visible with scanning/queued indicators,
   including in top-five cards. Queue means the current batch, not a second scan.
6. **Popup lifecycle.** Outside click, Escape, icon toggle, and app deactivation
   close the popup. Remove event monitors on close and termination.
7. **Menu bar identity.** Icon only, no app-name text. Keep the drive a native template
   image and the colored badge a separate mouse-transparent view; a flattened
   non-template icon previously became black and unreadable.
8. **Accepted design.** Soft charcoal popup, muted text/accent colors, teal header.
   Do not restore the bright white or washed-out translucent background. Settings
   has Quit in the footer and Back fixed above it on the right, no duplicate top Back button.
9. **Alert contract.** Red below 125 GiB; orange below 300 GiB, growth >=10 GiB, yellow ? for
   incomplete/failed tracked-root measurement or failed free-space check. Red > orange > yellow. Cancellation is not an alert.
   Keep code, boundary tests, settings legend, and docs consistent.
10. **Persistence.** Preserve `local.darien.diskmonitor`, interval keys, and existing
    JSON compatibility. Schema changes need explicit migration tests and a recovery
    plan; silent decode failure must not become an excuse to reset user data.

## Validation required by change

Build and run `--self-test` for runtime changes. Add focused regression coverage
when changing scanner, timers, persistence, alerts, or tree state. Exercise the
relevant manual acceptance checks for UI changes; say if they remain unverified.
Do not weaken tests to restore a previously rejected behavior. Keep validation
bounded and avoid unrelated full-machine work.
