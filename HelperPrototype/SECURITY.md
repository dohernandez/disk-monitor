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

- Three argument-free XPC operations: authenticated ping, fixed-target measurement, and cancellation of the helper’s own current measurement. It returns a total, timestamp or bounded
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
Cancellation now requests termination of the helper’s owned child and discards its result; live cancellation remains an acceptance gate. Disabling registration is not offered while a known request is in progress. No production integration or release signing change is made.

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

The next isolated acceptance series uses the distinct `spotlight-preview2` bundle
and service IDs so a newly approved test identity is not presented as an upgrade
to the prior identity. Two builds are prepared using the same certificate, with
increasing build numbers. Only that pair is eligible for the next upgrade test.
The first series is unregistered. This is a test migration, not a production update
strategy; no broad TCC/background-item reset is used.

## Resumed setup validation
The new source validates fixed package metadata, executable type and both pinned
signatures before offering registration. A valid package with service status
notFound can attempt explicit registration; an invalid package cannot. Fixtures
cover unsigned packages, mismatched program paths, linked executables and status
routing. `--check-package` runs the actual packaged verification without opening
UI, registering a helper or scanning anything.

Cancellation is requested through authenticated XPC with no PID/path input. A token
retains cancellation arriving before process attachment. The measure reply alone
confirms completion; a client deadline does not claim the OS process has exited.
Fixtures cover pre-cancellation and attachment ordering; live cancellation remains
unverified. A generated build number is logged at helper startup so paired builds
have distinct executable hashes while retaining the same signing identity.

The next test uses one visible app named Disk Monitor Setup, a separate unused
bundle/service identity, and two pre-signed builds. Retired previews stay archived.
This remains isolated from the production monitor and does not implement automatic
refresh in the production app yet. No PR is ready for release.

## September 24 build 6 → 7 acceptance (supersedes earlier pending results)

Build 6 measured successfully after explicit background approval and Full Disk
Access. Build 7 used the same certificate and designated requirements, with a
higher version and different executable hash. It passed static preflight but
initially failed the macOS launch constraint before any measurement request.

Recovery was tested without changing Full Disk Access: unregister; turn OFF only
Disk Monitor Setup in Login Items & Extensions; register again; turn background
approval ON; verify and measure. Build 7 then completed two scans (51.8 GB and
51.79 GB). This proves this recovery sequence on this Mac, not unattended upgrade
retention or reliability across future updates and operating systems.

The revised client now offers an explicit repair flow after connection timeout.
It unregisters before guiding the background off/register/on sequence, checks
requiresApproval before advancing, and never changes macOS permissions itself.
A successful measurement displays a monotonic countdown before another request;
the helper retains its own 60-second throttle. Revised client compilation and
existing helper fixtures passed; these UI changes are not installed or visually
accepted yet. No new signing identity was created for these checks.

Production packaging remains pending. It needs a dedicated stable self-signed
code-signing key in the main-only release environment, separate from Sparkle and
absent from runtime Macs. Neither the retired prototype key nor ad-hoc identity
checks can substitute for that release identity. Ordinary tracked folders must
never acquire privileged path access through this integration.

## Integrated signing boundary

A hardened self-signed main app failed to launch with the existing Sparkle framework:
dyld rejected the different Team IDs. The experiment did not install anything; its
private test key was retired. Library validation was not disabled.

The integration instead embeds Disk Monitor Scanner.app, a self-signed hardened
client with only Apple frameworks. Its Bridge executable accepts exactly status,
register, unregister, measure or cancel, with no additional arguments. The root
helper authenticates this bridge identity. Disk Monitor validates the nested bundle
and fixed helper signatures before executing the bridge, uses a clean environment
and bounded JSON transport, and never passes paths, shell commands or secrets.
The normal main app retains its existing updater/signing policy. The nested host
and helper retain hardened runtime and library validation.

Any local user able to execute the signed bridge can request its fixed operations;
client authentication is not a per-user authorization boundary. Background approval
and broad FDA remain explicit macOS grants. This does not extend access beyond the
fixed read-only Spotlight operation or allow elevated writes. A hostile process
already acting as the user can influence the unprivileged UI, but cannot sign a new
bridge or helper without the isolated release key.

The implementation records the current boot identifier before requesting a scan.
An unconfirmed request blocks new scans and updater relaunch even after the app
restarts. A confirmed reply clears the marker; otherwise a different boot identifier
is required. The UI permits quitting and explains that a Mac restart is needed.
Failure to obtain a boot identifier stays blocked. This conservative recovery path
does not claim that disconnection or unregister stopped the child. Live crash/reboot
acceptance remains required.

The user subsequently exercised build 7 cancellation: screenshots show measurement
in progress followed by “Measurement cancelled”. Unregister then removed the service;
no fixed-path du remained at the post-unregister check. The source now labels this
as cancellation rather than failure. This preview evidence does not establish the
integrated bridge's cancellation or disconnected-child recovery behavior.
