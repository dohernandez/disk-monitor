# Development and recovery

Read [AGENTS.md](../AGENTS.md) and the [acceptance checklist](ACCEPTANCE.md) first.
Run commands from the project root. Documentation changes alone do not require
building or restarting the app.

## Build and test

```sh
sh -n build.sh
sh build.sh > build.log 2>&1
"build/Disk Monitor.app/Contents/MacOS/DiskMonitor" --self-test
codesign --verify --deep --strict "build/Disk Monitor.app"
```

Keep the complete build log when diagnosing failure. A successful build creates
`build/Disk Monitor.app`, writes Info.plist, and ad-hoc signs the bundle. The script
changes into its own directory, so it works when called from elsewhere. It compiles
Swift app and updater files with Cocoa, SwiftUI and Sparkle, optimization enabled and Swift 5 language mode.
Sparkle is downloaded at build time using a pinned checksum and embedded in the app.

The self-test runs real `du` against a disposable 1 MiB fixture, including a directory
with spaces, missing-path error, and pre-cancellation. It exercises asynchronous
collapse/reopen, scan/queue path states, alert boundaries and deduplication, cancelled
error handling, timer replacement, invalid intervals, and preference persistence in
a unique UserDefaults suite. Successful output:

```text
PASS: scanner, folders, scan/queue states, alerts, configurable timers and preference persistence
```

It does not launch the normal UI or intentionally scan tracked roots. Model instances use temporary readings files and query filesystem capacity. Fixture data and the test preference suite are removed
on success. It does not exercise live mid-process cancellation, appearance, or popup
click behavior. Extend focused tests when changing those contracts.

## Command Line Tools workaround

Some local CLT installations contain both `swift/module.modulemap` and
`swift/bridging.modulemap`, causing duplicate SwiftBridging definitions. `build.sh`
creates a project-local empty module map and VFS overlay only when both exist.
The overlay is passed to both Swift (`-vfsoverlay`) and Clang (`-Xcc -ivfsoverlay`).
Do not remove one side without reproducing and checking the build. Never edit or
remove the system module maps. Module cache and overlay are generated under `build/`.
A cold build can take substantially longer than a warm one.

Do not infer OS support from LSMinimumSystemVersion alone. Check the actual toolchain
and binary deployment target before distribution; the mismatch is recorded in
[Architecture](ARCHITECTURE.md).

## Safe update procedure

1. Inspect current source and running state. For a runtime change, retain a copy of
   the known-working source, build script, and app bundle outside `build/` before
   compiling. The script overwrites the current bundle in place.
2. Preserve user data and preferences before any storage-format change. Do not copy
   them into a public repository or reset them as part of a normal upgrade.
3. Build, run the fixture self-test, and check signing. Do not launch a failed or
   partially built bundle. Review the relevant acceptance checks.
4. Stop any active scan through the app, then use the footer power button (**Quit Disk Monitor**).
   Confirm the exact old process exited. `pgrep -fl DiskMonitor` is for discovery;
   inspect `ps -p <PID> -o pid,ppid,command` and its children before acting on a PID.
   Do not use `pkill -f` or kill unrelated `du` processes.
5. Launch the verified bundle once:

   ```sh
   open "build/Disk Monitor.app" --args --show
   ```

6. Check the icon, settings, cached readings, and changed behavior. Normal launch
   may automatically scan stale roots after 0.6 seconds; launching is not a scan-free
   UI test. Avoid additional expensive scans unless needed. Do not enable a login
   item or install into Applications as an incidental part of an edit.

Building while the old process exists does not update its in-memory code. Explicit
quit/relaunch avoids mistaking an old UI for the new version. Launch Services may
reuse an existing instance, so `open --args --show` is not a reliable hot reload.

## Backups and rollback

For example, before a runtime edit:

```sh
backup_dir="$(mktemp -d "$HOME/DiskMonitor-backup.XXXXXX")"
cp main.swift build.sh "$backup_dir/"
ditto "build/Disk Monitor.app" "$backup_dir/Disk Monitor.app"
printf '%s\n' "$backup_dir"
```

Keep that printed path. This copies only project artifacts, not monitored folders.
For a data-format change, quit the app first, then separately copy the readings JSON
if it exists and export the app preferences with
`defaults export local.darien.diskmonitor <backup.plist>` (a missing domain may fail).
Use a private backup location. Do not reset preferences during ordinary updates.

If a new build regresses, quit it and launch the preserved bundle by its exact path.
Restore the matching source/build script before further development. If a new version
changed storage, use its documented reverse migration or restore the explicitly saved
pre-upgrade state while the app is stopped; restoring a backup loses measurements
made afterward. There is no automated rollback or migration in this version.

## Troubleshooting

| Symptom | First check |
|---|---|
| Free space changed but folder sizes did not | The timers are separate; inspect folder interval and measurement timestamps |
| Orange icon with plenty of space | Read Needs Attention for large folder growth |
| Yellow question-mark badge | Incomplete/failed folder or free-space measurement; inspect its error |
| Old size remains after a failed scan | Intentional preservation of complete data; read error and timestamp |
| Deep child has no size or an old size | Ancestor scan only emits depth 2; scan the child or track it separately |
| Expanding appears stuck | Directory loading is separate from `du`; check loading/error state, preserve collapse semantics |
| Preferences appear lost | Verify bundle ID, defaults keys, launch identity, and decode errors before touching data |
| Blank/stale top-five entry | Check cached paths and candidate rules; the app does not prune stale readings |
| New UI did not appear | Verify the process was actually quit and the intended bundle launched |
| SwiftBridging redefinition | Inspect build log and local overlay, not system toolchain files |

Visual inspection currently relies on the user or a deliberate manual check. ChatGPT
Computer Use permissions are unrelated to running this app and are not a prerequisite.

Menu bar recovery: AppDelegate is retained across app.run. DiskMonitor-status is the stable autosaveName; its own preferred-position key is seeded to 0 only when absent. The September 21 missing-icon incident was resolved by repositioning away from the notch, confirmed by the user; the lifetime guard alone did not resolve it. Launch --diagnostics logs startup and item geometry to /tmp/DiskMonitor-launch-diagnostic.jsonl. Match PID/time and compare frame to NSScreen.auxiliaryTopRightArea; isVisible alone is insufficient. Command-drag preserves the user’s chosen position. Do not reset global preferences or other apps.
