# Releases, installation and main-branch protection

Version **1.0.0** is the first stable version. Stable describes the accepted feature
baseline; builds are still **ad-hoc signed, not Apple Developer ID-signed or notarized**.
Only the public update key is stored in this repository; private signing seeds and
Apple credentials are not.

## Install a release

1. Download the `.dmg` from this repository’s Releases page: **arm64** for Apple
   Silicon, **x86_64** for Intel. Both require macOS 15 or later.
2. Optionally check the download with `shasum -a 256 -c <filename>.dmg.sha256` from
   the directory containing both files.
3. Quit the previous app, open the DMG, and drag the app onto Applications.
4. Launch the copy in Applications, then eject the DMG. The app lives in the menu
   bar; Command-drag its icon to reposition it. Do not run duplicate copies.

The app’s bundle identity and user-data paths are unchanged. Replacing the app does
not reset settings, readings, or token history. No login item or agent hook is installed.

An unnotarized internet download can be blocked by Gatekeeper. If you trust the
source and have checked the download, use macOS **System Settings → Privacy &
Security → Open Anyway** after the blocked launch. Do not globally disable Gatekeeper.
Apple’s guidance: [Open a Mac app from an unknown developer](https://support.apple.com/guide/mac-help/open-a-mac-app-from-an-unknown-developer-mh40616/mac).

## CI flow

`.github/workflows/macos.yml` runs for PRs to `main`, pushes to `main` (including
merges), and manual dispatch. Closing a PR without merging never publishes a release.
Manual dispatch publishes only when run from `main`.

Every PR runs:

- **Commit signatures:** every new PR commit must be verified by GitHub.
- **Test and build (arm64):** native macOS 15 build, release helper tests, native
  self-tests, signature integrity, DMG creation/verification and mounted-app checks.
- **Test and build (x86_64):** the same checks on the Intel macOS 15 runner.

Token Monitor additionally runs its Python accounting/observer suite with the
bundled interpreter and a collector smoke test against a temporary empty home/state.
Neither installer verification nor CI installs an observer or reads real agent data.
Disk self-tests use temporary saved-state paths, including permission-migration fixtures.

After a main build passes all checks:

1. Reserve a semantic version tag at the exact tested commit.
2. Download those tested app bundles, stamp their release version, and re-sign locally.
3. Create one DMG and SHA-256 file per architecture; verify each mounted image.
4. Sign each final DMG and its architecture-specific appcast with Ed25519.
5. Verify both feeds and installers against the committed public key, upload all
   six assets to a draft, then publish it. Missing or invalid signatures stop publication.

The workflow uses the repository `GITHUB_TOKEN`; no personal `GH_TOKEN` is needed. Signing uses `SPARKLE_PRIVATE_KEY` from the
`release` environment, restricted to the `main` branch. PR jobs cannot access it.
It does not depend on a release event starting another workflow. PR jobs have no
repository write permission. Only version reservation and publication can write.
Action versions are pinned to commit SHAs.

## Version policy and recovery

`VERSION` sets the initial release floor, **1.0.0**. Later versions derive from the
highest existing `vMAJOR.MINOR.PATCH` tag and the merged PR’s branch:

| Prefix | Bump |
|---|---|
| `major*`, `release*` | Major |
| `minor*`, `feature*`, `feat*` | Minor |
| Anything else (`fix/`, `patch/`, `docs/`, dependencies) | Patch |

Direct main pushes and manual dispatch without a matching merged PR default to patch.
Main protection is intended to prevent direct pushes. Never rename or move a release tag.
A rerun at an already tagged commit reuses its version. Concurrent merges reserve tags
with non-forced pushes and retry collisions; there is no shared pending-run queue that
drops intermediate main commits. Version order follows successful reservation order.

A packaging failure can leave a reserved tag without a published release. Fix a
transient runner failure by rerunning that workflow; its tag and source commit stay
fixed. Do not delete the tag just to reclaim a version. Published releases are not
overwritten by reruns. Incomplete drafts may have their assets replaced before publishing.

`APP_VERSION`, `APP_BUILD` and `BUILD_DIR` support isolated builds. Without overrides,
`sh build.sh` uses `VERSION`, build number 1, and `build/`. Keep source-build and
release-package versioning distinct: release packaging stamps the reserved version
into both the bundle metadata and visible header.

To build a local installer (use a new output folder if the name already exists):

```sh
BUILD_DIR=/tmp/monitor-release-build sh build.sh
python3 scripts/package.py --app '/tmp/monitor-release-build/Disk Monitor.app' --version 1.0.0 --output dist
```

The package helper makes a copy before changing metadata. It never installs the app
or modifies the input bundle. Checks include running `--self-test` inside the mounted
read-only image. Updating the running local app remains a separate deliberate step.

## Branch rules

The intended rules live in `.github/main-ruleset.json`:

- PR required; zero approving reviews for the current solo-maintainer workflow.
- Verified signatures required for incoming commits.
- All three checks above required from the GitHub Actions integration.
- Branch must be up to date before merging; review conversations must be resolved.
- No force-pushes, deletions, or administrator bypass list for `main`.

**Activation verified (2026-09-22): active.** This repository is public. GitHub
Free enforces the rules above; secret scanning and push protection are also enabled.
The server configuration was read back separately from the committed ruleset file.
Use `scripts/apply_main_rules.py --validated-ref <branch>` only after the required
checks pass when deliberately updating the rules.

The helper checks the actual check names, integration and successful conclusions,
then creates or updates only the ruleset named “Protect main” and reads it back.
It never changes repository visibility, billing, unrelated rulesets, or credentials.

Signed commits can be made locally using a registered signing key, or through
GitHub’s signed web/GraphQL commit interface. Unsigned PR commits can block a merge
even if GitHub would sign the final squash commit. See [GitHub’s signing rules](https://docs.github.com/en/repositories/configuring-branches-and-merges-in-your-repository/managing-rulesets/available-rules-for-rulesets).

## Apple signing is a separate follow-up

Git commit signatures establish commit authorship; they do not sign the macOS app.
Developer ID signing and Apple notarization need Apple Developer Program credentials.
Before enabling them, import the certificate into a temporary CI keychain, sign
nested executable code inside-out with hardened runtime, notarize the final package,
staple its ticket, and verify it with Gatekeeper on a clean Mac. Never label an ad-hoc
build notarized. No automatic notarization is configured in this workflow.

## Signed in-app updates

Settings offers **Check for Updates**, daily automatic checks, and automatic
background download/installation. Both automatic choices default off and save
immediately through Sparkle preferences; they are separate from measurement timers.
Automatic installation normally occurs on quit. A requested updater relaunch waits
for the app's active scan/collector to finish. No login item is added.

The first release containing this feature requires one manual installation: version
1.0.0 does not contain an updater. Subsequent releases use Sparkle 2.10.0, pinned by
URL and SHA-256 in `scripts/sparkle.py`. Framework licenses remain inside the bundle.
The installer **and the appcast** are Ed25519-signed. `SUPublicEDKey` is embedded in
the app; `SURequireSignedFeed` and `SUVerifyUpdateBeforeExtraction` require verification
before trusting feed content or extracting an update. SHA-256 sidecars alone do not
establish authenticity. These update signatures do not provide Apple notarization.

The architecture-specific HTTPS feed is a GitHub Release asset:
`releases/latest/download/appcast-arm64.xml` or `appcast-x86_64.xml`. Versioned DMG
URLs are inside the signed feed. Checks disclose normal HTTP metadata (including IP
address and app user agent) to GitHub, but no measurements, usage records or system
profile. Profiling is disabled and the delegate's profile allowlist is empty.

### Key custody and CI

`scripts/update-config.json` contains only the repository and public key. Each app
has a separate seed, stored locally in the login Keychain under Sparkle's account
`dohernandez.disk-monitor`. An exported copy is installed as the `release` environment
secret, never a repository file or PR secret. Exported temporary files are owner-only
and removed after upload. Keep a separate secure backup before moving Macs or
removing the Keychain item. Losing this key can require a manual reinstall; do not
silently replace the embedded public key and assume existing users can update.

Only trusted main release jobs receive the seed. `sign_release.py` verifies that
its derived public key matches the app configuration before signing. The publication
job has no private key: `verify_release.py` uses CryptoKit to verify feed bytes and
DMG bytes using the committed public key. It also checks the expected version, URL,
and file size. PR checks use random, disposable seeds to prove valid signatures pass
and changed downloads, changed/unsigned feeds, and wrong keys fail.

For local signature regression checks after a build:

```sh
SPARKLE_TOOLS=build/sparkle python3 -B scripts/test_signatures.py
```

`scripts/check_updater.py` starts the embedded updater in a temporary app identity,
with automatic options disabled and no update UI. No test replaces or launches an installed app. Full interactive update/relaunch and
Gatekeeper acceptance on a clean Mac remain manual acceptance checks. Verify these
before claiming end-to-end installation acceptance. An older signed feed can be
replayed to delay update discovery; installed build comparison prevents it being
used to offer an older build as a newer one. Protect GitHub access and the signing
key independently.

## Experimental scanner packaging

`SCANNER_SIGNING_SHA1` is an optional public certificate fingerprint for isolated
build validation, not a credential. When absent, the build contains no privileged
scanner and cannot register one. When present, the signer must already be available
in the build keychain. The nested Disk Monitor Scanner.app and its helper are signed
inside-out with hardened runtime and no library-validation exemption. The parent
app keeps its existing signing policy and updater.

Never place the scanner private key on runtime Macs, commit it or expose it to PR
jobs. A dedicated stable release key must be provisioned before enabling this
feature in releases. Prototype keys are temporary
and retired; they are not release identities. The installer may re-sign only the
outer ad-hoc app and must preserve and verify the nested scanner's signature.
The legacy direct-in-main-app helper layout is rejected by packaging.

Run scripts/test_scanner_build.py and, for an isolated signed build,
`DiskMonitor --scanner-package-self-test` before any installer acceptance. Neither
command registers or measures. Live cancellation, guided setup, update/reapproval,
restart and clean-Mac acceptance are separate from successful compilation.

The release environment can enable scanner packaging with `SCANNER_RELEASE_ENABLED=true`,
public variable `SCANNER_SIGNING_SHA1`, and secrets `SCANNER_P12_BASE64` and
`SCANNER_P12_PASSWORD`. Leave the enable flag off until integrated acceptance passes.
`scripts/build_signed_scanner.py` rejects PR and non-main execution, imports the
dedicated certificate into a disposable CI keychain, verifies its public fingerprint,
builds the same checked-out commit, and restores the keychain list and deletes its
temporary keychain in a finally block. Credentials are removed from the build
subprocess environment. The signed rebuild runs native, package and updater checks
before packaging. A cancelled runner is disposable; it must never be a runtime Mac.
Provisioning and secure backup of that stable identity are still outstanding.
