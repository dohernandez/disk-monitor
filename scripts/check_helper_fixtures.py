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
