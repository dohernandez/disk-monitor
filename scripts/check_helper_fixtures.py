"""Compile/run unprivileged helper fixtures using a dummy public fingerprint."""
import platform
from pathlib import Path
import subprocess
import sys

root = Path(__file__).resolve().parent.parent
build = Path(sys.argv[1] if len(sys.argv) > 1 else root / 'build').absolute()
build.mkdir(parents=True, exist_ok=True)
identity = build / 'FixtureScannerIdentity.swift'
identity.write_text('let signingCertificateSHA1 = "' + '0' * 40 + '"\nlet scannerBuildNumber = "fixture"\n')
source = root / 'HelperPrototype'
args = ['xcrun', 'swiftc', '-D', 'DISK_MONITOR', '-swift-version', '5', '-target', platform.machine() + '-apple-macos15.0', '-parse-as-library',
        '-vfsoverlay', str(build / 'toolchain-overlay.json'), '-Xcc', '-ivfsoverlay', '-Xcc', str(build / 'toolchain-overlay.json'),
        '-module-cache-path', str(build / 'scanner-fixture-modules')]
args += [str(source / name) for name in ['Shared.swift', 'RequestState.swift', 'RecoveryState.swift', 'BundlePolicy.swift', 'Measurement.swift', 'Tests.swift']]
args += [str(identity), '-o', str(build / 'scanner-fixtures')]
subprocess.run(args, check=True)
subprocess.run([str(build / 'scanner-fixtures')], check=True, timeout=60)

# Compile production IPC endpoints too: unsigned PR builds do not bundle them.
# Compilation never registers or executes these binaries.
base = args[:args.index(str(source / 'Shared.swift'))]
for name, files in [
    ('scanner-compile-check', ['Shared.swift', 'Measurement.swift', 'Helper.swift']),
    ('bridge-compile-check', ['Shared.swift', 'BridgeProtocol.swift', 'Bridge.swift']),
]:
    subprocess.run(base + ['-D', 'DISK_MONITOR'] + [str(source / file) for file in files]
                   + [str(identity), '-framework', 'ServiceManagement', '-o', str(build / name)], check=True)
print('PASS: production scanner and bridge compile without signing, registration or execution')

# Prove that a non-primary executable resolves the enclosing main app bundle.
# This explicit entry point never constructs SMAppService or connects to a daemon.
import tempfile, plistlib, shutil
with tempfile.TemporaryDirectory(prefix='scanner-container-') as directory:
    app = Path(directory) / 'Disk Monitor.app'
    macos = app / 'Contents/MacOS'
    macos.mkdir(parents=True)
    (app / 'Contents/Info.plist').write_bytes(plistlib.dumps({
        'CFBundleIdentifier': 'local.darien.diskmonitor', 'CFBundleExecutable': 'DiskMonitor',
        'CFBundlePackageType': 'APPL'}))
    shutil.copy2(build / 'bridge-compile-check', macos / 'ScannerBridge')
    subprocess.run([str(macos / 'ScannerBridge'), '--bundle-self-test'], check=True, timeout=10)

# Registration belongs to DiskMonitor, never this secondary signing identity.
# These rejected commands must exit before creating IPC or touching SMAppService.
for operation in ('status', 'register', 'unregister'):
    result = subprocess.run([str(build / 'bridge-compile-check'), operation], capture_output=True, timeout=10)
    assert result.returncode == 2 and not result.stdout, 'Bridge must reject service-management operations'
print('PASS: internal bridge cannot register or manage the app service')

# Exercise launch constraints with the kernel, without registering a service.
# The invalid argument exits at the helper's first guard, including when run as root.
from scanner_constraint import SERVICE, constraint, check as check_constraint
launch_check = build / 'launch-constraint-check'
compiler = base.copy()
compiler.remove('-parse-as-library')
subprocess.run(compiler + [str(root / 'scripts/check_launch_constraint.swift'), '-o', str(launch_check)], check=True)
with tempfile.TemporaryDirectory(prefix='scanner-launch-') as directory:
    app = Path(directory) / 'Fixture.app'
    scanner = app / 'Contents/MacOS/Scanner'
    scanner.parent.mkdir(parents=True)
    shutil.copy2(build / 'scanner-compile-check', scanner)
    subprocess.run(['codesign', '--force', '--sign', '-', '--identifier', SERVICE, str(scanner)], check=True)
    plist = app / f'Contents/Library/LaunchDaemons/{SERVICE}.plist'
    plist.parent.mkdir(parents=True)
    expected = constraint(app)
    plist.write_bytes(plistlib.dumps({'SpawnConstraint': expected}))
    check_constraint(app)
    subprocess.run([str(launch_check), str(app)], check=True, timeout=20)
    plist.write_bytes(plistlib.dumps({'SpawnConstraint': dict(expected, cdhash=b'\0' * 20)}))
    try:
        check_constraint(app)
    except ValueError:
        pass
    else:
        raise AssertionError('Stale scanner hash passed package validation')
    plist.write_bytes(plistlib.dumps({}))
    try:
        check_constraint(app)
    except ValueError:
        pass
    else:
        raise AssertionError('Missing launch constraint passed package validation')
# Main-only builds additionally test the real release-signed executable.
release_app = build / 'Disk Monitor.app'
if (release_app / 'Contents/MacOS/Scanner').exists():
    check_constraint(release_app)
    subprocess.run([str(launch_check), str(release_app)], check=True, timeout=20)
