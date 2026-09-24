# Spotlight helper experiment (not shipped)

This directory is an isolated prototype for read-only, administrator-authorized
Spotlight index measurement. It does not modify Disk Monitor's normal app,
preferences, updater or saved measurements. Read [SECURITY.md](SECURITY.md) before
building. This is not ready for installation by other users.

## Source map

- `Shared.swift`: fixed identities and argument-free XPC protocol.
- `Helper.swift`: authenticated listener, serial admission and throttling.
- `Measurement.swift`: fixed system tool/path, ancestor guards and strict results.
- `Client.swift`: guided preview with connection handshake and independent deadlines.
- `RequestState.swift`: monotonic deadline and stale-response rules.
- `Tests.swift`: disposable filesystem fixtures and request lifecycle regressions.
- `AuthTests.swift`: signed anonymous XPC authentication tests (no root service).
- `build.py`: isolated development signing and test build; never registers or installs.

## Developer validation

On macOS 15 with Command Line Tools, use a new private output directory:

```sh
PREVIEW_BUILD=4 python3 HelperPrototype/build.py /tmp/disk-helper-review-build
```

This creates an isolated test signing keychain and builds/tests the preview.
It does not alter certificate trust or launch a scanner. Do not commit generated
files, passwords or private keys. Retire the temporary private signing identity
before approving a privileged test installation. A retired identity cannot sign
another update; plan same-identity builds before retirement. Never silently rotate
an approved helper's identity or lower its bundle version.

No root scan or password prompt is part of automated tests. Live registration,
Full Disk Access, upgrade and removal tests are explicitly separate and remain
incomplete. See the exact acceptance results and blockers in SECURITY.md.
