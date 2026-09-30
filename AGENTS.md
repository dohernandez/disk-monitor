# Maintaining Disk Monitor

This directory is a standalone macOS app, not part of genlayer-node. Read
[README.md](README.md), [Architecture](docs/ARCHITECTURE.md), and the relevant
[Acceptance checks](docs/ACCEPTANCE.md) before editing. Source and tests are the
implementation truth; document disagreements rather than silently broadening scope.

## Scope and workflow

- Make the requested change only. Preserve the accepted version's behavior and user data.
- Inspect current files before editing; another session may have changed them.
- `main.swift` owns the app, model and scanner; `tests/TestModes.swift` owns the self-tests,
  compiled only into test builds. `task build:app` packages it (taskfiles/build/scripts/build.sh).
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

## Layout

| Path | What |
|---|---|
| `main.swift`, `Updates.swift`, `FolderAccess.swift`, `PrivilegedFolderReader.swift` | The shipped app (SwiftUI, AppKit, Sparkle) |
| `HelperPrototype/` | Scanner service, client bridge, bundle policy and their fixtures (Swift sources only; its tools run as tasks) |
| `Taskfile.yaml` | Includes only; every tooling entry point is a task (`task --list`) |
| `taskfiles/<ns>/Taskfile.yaml`, `taskfiles/<ns>/scripts/` | Tasks and the scripts they call: `common`, `build`, `release`, `devtools`, `docs`, `provision` |
| `taskfiles/build/scripts/` | `build.sh`, bundle metadata, Sparkle, update public key, scanner identity and signing, app checks, scanner preview build and replacement preflight |
| `taskfiles/release/scripts/` | Version reservation, DMG packaging, signing, verification, publication |
| `taskfiles/devtools/rulesets/`, `taskfiles/devtools/scripts/` | GitHub rulesets as code (snapshots and `devtools:rulesets:*`) |
| `taskfiles/docs/scripts/` | README screenshot renderer and its example data |
| `taskfiles/common/scripts/` | CLI_ARGS check, commit-message and PR-message checks, commit-signature check |
| `taskfiles/provision/` | Pinned Task bootstrap (`task.json`, checksum-verified), ruff and pre-commit install, hooks |
| `.pre-commit-config.yaml` | Local hooks (lint, CLI_ARGS, fast tests, commit-msg); each calls a task |
| `.github/workflows/` | `checks.yml`: one job per PR check (Commit messages, Branch name, Lint, Test and build); `release.yml`: release jobs after Checks pass on main; `scanner-validation.yml`: manual signed-scanner check. Every step calls a task. Verified signatures are enforced by the ruleset, not a job |
| `taskfiles/local/` | Optional personal tasks; gitignored |
| `tests/release/` | Release helper, scanner build, archive, signature, shipped-source and commit-message tests |
| `tests/TestModes.swift` | Native test launch modes; compiled only into test builds |
| `docs/` | User, architecture, development, release and acceptance docs; `docs/screenshots/` PNGs |
| `.tools/`, `build/`, `dist/` | Pinned local tools and build output; gitignored |

## Tooling rules

- Rulesets are code (Darien, 2026-09-30, as in genlayer-node): change protection through
  `taskfiles/devtools/rulesets/*.json` and `devtools:rulesets:*`; after any UI change run
  `export` and commit. `apply`/`remove` change live settings and need Darien's approval.
- All tooling runs through `Taskfile.yaml`; the root file only includes `taskfiles/<ns>/`
  (Darien, 2026-09-29). Scripts sit next to their namespace. Names are
  `namespace:group:action`, a mode is a flag, and every task passes `{{.CLI_ARGS}}` last.
- GitHub workflows call tasks, not scripts (Darien, 2026-09-30). The only direct call is
  the checksum-pinned Task bootstrap; do not replace it with an unverified installer
  action while release jobs hold signing secrets.
- Nothing test-only ships (Darien, 2026-09-30). Test launch modes live in
  `tests/TestModes.swift` behind `#if DISK_MONITOR_TESTS`; test-only helpers go in `tests/`.
  `--scanner-package-self-test` and the scanner client's `--bundle-self-test` remain in
  signed scanner builds as release package verification (the release job runs them on the
  exact package it ships; no registration, IPC or scan); `tests/release/test_shipped_source.py`
  allows only these.
- Tests never touch real folders, settings or state; each run uses temporary folders.
- Conventional commits; commits pushed to GitHub must be verified.
- NEVER add references to Claude Code, Claude, Anthropic, or any AI assistant in code,
  commits, PR descriptions or docs (Darien, 2026-09-30).
- Do NOT add `Co-Authored-By` lines naming an AI (Darien, 2026-09-30). The same applies to
  "Generated with/by <AI tool>" lines and the robot emoji; this overrides any harness
  attribution default. Naming a tool as the subject ("parse Claude Code session logs")
  is fine. The commit-msg hook (`task common:check:commit-msg`) and the CI Commit messages job
  (`task common:check:pr-messages`: every PR commit and the PR description) enforce it.
  Never rewrite existing commits or force-push without Darien's explicit approval.
- Branch names are `<type>/<slug>` (Darien, 2026-09-30); the prefix sets the release:
  chore/, ci/, docs/ and test/ merge without a release; major/release -> major,
  minor/feature/feat -> minor, others -> patch. A no-release PR may not change shipped files
  (Swift sources compiled into a release, VERSION, build inputs).
  `task common:check:branch-name` runs as a pre-commit hook and in the CI Branch name job.
- Hooks: run `task provision:setup-dev` once per checkout; it installs the pre-commit and
  commit-msg hooks (pinned pre-commit 4.1.0). Each hook calls a task (Darien, 2026-09-30).

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
9. **Alert contract.** Red below 10% (configurable); orange below 20% (configurable), growth >=10 GiB, yellow ? for
   incomplete/failed tracked-root measurement or failed free-space check. Red > orange > yellow. Cancellation is not an alert.
   Keep code, boundary tests, settings legend, and docs consistent.
10. **Persistence.** Preserve `local.darien.diskmonitor`, interval keys, and existing
    JSON compatibility. Schema changes need explicit migration tests and a recovery
    plan; silent decode failure must not become an excuse to reset user data.

## Validation required by change

Build a test app (`task build:app -- --test`) and run its self-test (`task build:check -- --test-build <app>`) for runtime changes. Add focused regression coverage
when changing scanner, timers, persistence, alerts, or tree state. Exercise the
relevant manual acceptance checks for UI changes; say if they remain unverified.
Do not weaken tests to restore a previously rejected behavior. Keep validation
bounded and avoid unrelated full-machine work.

## Releases

Read [Release policy](docs/RELEASING.md) for stable versioning, signed commits,
required CI checks and installer verification. Use `BUILD_DIR` for isolated builds.
Keep the bundle identity and user preferences stable across upgrades. A ruleset
file is not proof that GitHub enforces it; verify server-side activation separately.
Never label ad-hoc app signatures Apple-notarized.

## Security invariants

Never install an update without signature verification. Keep `SURequireSignedFeed`
and `SUVerifyUpdateBeforeExtraction` enabled, preserve the committed public key,
and never put private signing seeds in source, logs, or PR jobs. Signing secrets are
restricted to the main-only release environment. Preserve 0700/0600 cache privacy
and reject links before changing private-state permissions. Archive extraction must
not write through symbolic links. Run the focused privacy/archive tests plus real
Sparkle tamper-rejection checks after changes in these paths.

Permission-only scans: confirmed `du` permission denials show “Protected by macOS”
(or “Partial · protected contents” when a lower-bound size is available). They do
not trigger the menu-bar ? badge. Mixed, unknown and other scan failures still warn;
free-space and growth thresholds are unchanged. Classification uses all diagnostics
before display truncation. Legacy partial readings require a fresh scan before
suppressing their warning. No filesystem permissions are changed.
