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
args = ['xcrun', 'swiftc', '-swift-version', '5', '-target', platform.machine() + '-apple-macos15.0', '-parse-as-library',
        '-vfsoverlay', str(build / 'toolchain-overlay.json'), '-Xcc', '-ivfsoverlay', '-Xcc', str(build / 'toolchain-overlay.json'),
        '-module-cache-path', str(build / 'scanner-fixture-modules')]
args += [str(source / name) for name in ['Shared.swift', 'RequestState.swift', 'BundlePolicy.swift', 'Measurement.swift', 'Tests.swift']]
args += [str(identity), '-o', str(build / 'scanner-fixtures')]
subprocess.run(args, check=True)
subprocess.run([str(build / 'scanner-fixtures')], check=True, timeout=60)
