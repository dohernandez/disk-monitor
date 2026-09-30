# Changelog

## Unreleased

- Keep test launch modes (`--self-test`, `--updater-self-test`, `--diagnostics`, `--show`) out of release builds; they are compiled only into test builds.
- Add signed Sparkle updates, manual checking and optional automatic updates.
- Enforce owner-only cache permissions while preserving saved data.

## 1.0.0

First stable release of Disk Monitor.

- Preserve the accepted menu bar dashboard, alerts, saved settings and measurements.
- Show the bundle version instead of a draft label.
- Add separate Apple Silicon and Intel DMG builds for macOS 15+.
- Validate PRs and generate versioned downloads automatically after merge.
- Document the intended main-branch rules and current GitHub plan restriction.

Downloads are ad-hoc signed; Apple notarization is not configured.
