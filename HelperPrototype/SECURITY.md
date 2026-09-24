# Isolated Spotlight helper prototype — not a release feature

Goal: automatic, fixed-target Spotlight size measurements without storing a password
or granting Full Disk Access to Apple's shared authorization trampoline. v1.6.0's
AppleScript operation was authorized but denied by TCC. Re-enabling the app's own
Full Disk Access did not resolve it in the user's test.

This prototype does not change the installed Disk Monitor app, its cache or updater.
It uses separate bundle/service identifiers. build.py only builds and signs; it
never launches, installs or registers the helper. Its private test signing identity
lives in a separate 0700 build directory/keychain. No certificate is globally
trusted; login keys and existing signing secrets are not used. The original user
keychain search list is restored if creating the isolated keychain changes it.

## Privileged surface

- Two XPC operations, no input arguments: an authentication-only ping and a fixed-target measurement. It returns a total, timestamp or bounded
  generic error. No arbitrary paths, shell commands, credentials, files or options.
- Mutual NSXPCConnection code requirements pin the self-signed certificate and exact
  peer identifier. No acceptance of merely intact ad-hoc signatures or identifier-only
  checks. Hardened runtime is enabled without disabling library validation.
- Only fixed /System/Volumes/Data/.Spotlight-V100 is measured. Ancestors are opened
  with O_NOFOLLOW; non-root ownership, group/world writability and any ACL fail closed.
  Trusted system ancestors must not be replaceable by an unprivileged user.
- Only Apple's absolute /usr/bin/du is spawned, with separate fixed arguments,
  physical symlink handling, one filesystem, a clean environment and / as cwd.
  No elevated writes to user paths or app-supplied executables. No disk cache in daemon.
- Serial admission, rejection while busy, 60-second minimum interval (including
  errors), bounded stdout, generic errors instead of private filenames.
- At 15 minutes the helper sends termination to its own du Process. Kernel I/O can
  delay termination; this is not a guarantee of hard wall-clock completion. No broad
  process matching or PID files. Failed, timed-out or partial results contain no size.
- The prototype has no launch-at-login client, automatic measurement, network access,
  credentials storage or Sparkle flow. Periodic app integration comes only after the
  root/FDA/identity tests pass. The registered daemon is demand-launched by launchd.

## Threat boundaries and unresolved gates

The operating system, root users and the signing private key are trusted. A compromised
signing key can authorize replacement code: local key protection and future CI custody
are release requirements. Private test keys must never enter git or a public installer.

A self-signed development workflow is documented by Microsoft's ProcexpForMac; its
README and identity-creation script contradict one another about registration.
This is not proof that it solves Spotlight Full Disk Access or distribution for us:
https://github.com/microsoft/ProcexpForMac/blob/main/Helper/README.md

Before any production PR:
1. Prove stable signatures across two rebuilds and reject wrong-identity/modified code.
2. Verify real SMAppService registration and explicit user approval on this macOS.
3. Establish exactly which dedicated identity requires FDA; never grant authtrampoline,
   a general shell or a general-purpose command runner FDA as a workaround.
4. Verify successful fixed-target scan, failure and cancellation/timeout behavior;
   make the app preserve saved complete values on any error.
5. Rebuild/update with the same identity, restart helper and test approval/FDA retention.
6. Verify Disable unregisters the service; document precise removal/recovery.
7. Resolve signed release identity custody, Sparkle compatibility and Intel validation.
   Do not disable signature enforcement or library validation to pass this gate.

macOS can grant FDA broadly even though this helper's API is narrow. That broader
privilege and persistent registration require explicit user review. No claim of
independent security audit, notarization, or production readiness is made.

## Local proof collected

On macOS 15.7.4 arm64, native fixture scanning, parser bounds, symlink/owner/mode/ACL
rejection passed. Hardened self-signed binaries pass strict signature verification
without trusting the certificate globally or disabling library validation. Real
anonymous XPC fixture tests accept the pinned identity, reject a wrong client before
invoking the service, and reject a wrong server's reply. The latter may still receive
the empty request; the API intentionally sends no sensitive data or arguments.
Static identity checks also reject matching-ID ad-hoc impersonation and modified code.

These automated checks are unprivileged. Separate real-device results are recorded below.
Before registration, two preview builds are signed, and the private preview keychain
and its generated password are destroyed. Keeping an automatically usable signing
key beside a privileged helper would permit an attacker running as that user to
sign replacement trusted code. Production signing must be isolated from runtime Macs.

## Real-device acceptance update
Registration succeeded after user approval. TCC attributed the scanner to the
preview bundle; after the user enabled its FDA, ancestor checks passed and du ran.
The scan timed out at the original 180-second limit; no complete size was returned.
The next source revision uses a bounded 15-minute limit and elapsed-time display.
It has not replaced the installed preview. Successful scanning, cancellation,
upgrade retention, and production integration are still pending.

## Real-device findings and release blocker

The original preview registered after explicit approval, and one complete Spotlight
measurement succeeded after Full Disk Access was enabled for the preview app.
An earlier attempt reached its three-minute scan deadline. Unregister was confirmed
by both the preview and launchctl reporting the service absent.

A replacement built with a NEW signing identity and a LOWER bundle build number
registered but could not launch. launchd repeatedly reported EX_CONFIG and inability
to find/execute Contents/MacOS/Scanner; its job reported a code-requirement update
pending. The on-disk signature and executable permissions were valid. The exact
cause is unresolved; this is not evidence that another Full Disk Access change
would repair it. The failed service was subsequently unregistered.

The old client counted elapsed time before the helper responded, which misleadingly
looked like a running scan. The revised client requires an authenticated ping within
10 seconds BEFORE issuing a measurement. A separate monotonic response deadline,
connection failure handlers and request-generation guards prevent indefinite UI
waiting and stale callbacks. Timers do not prove that a du process is running.
The helper's scan budget is 15 minutes; the client allows 10 extra seconds for a
failure reply, then reports unknown scanner state. It does not claim the process
was terminated merely because the client stopped waiting.

The guided preview labels registration/approval/verification steps, links to macOS
settings, displays sizes with units and disables conflicting operations while busy.
The new UI is compiled but has not completed live visual/permission acceptance.
Cancellation is still a release blocker; disabling is not offered while a known
request is in progress. No production integration or release signing change is made.

Do not merge this prototype as an implementation of automatic scanning. Stable
same-identity upgrade acceptance, production signing custody, cancellation, clean-Mac
setup and Intel testing must precede integration. Existing release scripts do not
build or distribute this directory.

## Replacement rejection isolated
Earlier logs show an explicit code-signing launch-constraint violation before the
subsequent generic program-not-found errors. The replacement does not satisfy the
original app OR helper designated requirement; both comparisons were verified with
codesign. It also downgraded the build number. This is not a scan/FDA timeout.
A read-only replacement preflight now refuses both conditions. The two original
pre-signed builds pass this preflight; the rotated replacement fails. Stable-identity
live upgrades still need acceptance. No security policy was relaxed.

Apple DTS recommends comparing old and new designated requirements when diagnosing
this class of helper upgrade failure:
https://developer.apple.com/forums/thread/795022
