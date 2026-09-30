#!/usr/bin/env python3
"""Check a packaged app without opening its UI or reading real agent records."""
import json
import plistlib
import subprocess
import sys
import tempfile
from pathlib import Path
from bundle_info import APP_NAME, BINARY, IDENTIFIER

# Strings that only tests/TestModes.swift compiles in (long enough to be stored
# as bytes, unlike Swift's inline small strings).
TEST_MODE_MARKERS = (b'DISK_MONITOR_TEST_MODE', b'--updater-self-test', b'PASS: scanner, folders', b'DiskMonitor-launch-diagnostic')


def test_markers(app):
    binary = (Path(app) / 'Contents/MacOS' / BINARY).read_bytes()
    return [marker.decode() for marker in TEST_MODE_MARKERS if marker in binary]


def check_release_binary(app):
    found = test_markers(app)
    assert not found, 'Release binary contains test launch modes: ' + ', '.join(found)
    print('PASS: release binary contains no test launch modes')


def check_test_build(app):
    """Run the native self-tests in a test build (TEST_BUILD=1)."""
    app = Path(app).resolve()
    assert len(test_markers(app)) == len(TEST_MODE_MARKERS), 'Not a test build; build it with task build:app -- --test'
    subprocess.run(['codesign', '--verify', '--deep', '--strict', str(app)], check=True)
    output = subprocess.run([str(app / 'Contents/MacOS' / BINARY), '--self-test'], check=True, timeout=120, capture_output=True, text=True).stdout
    print(output, end='')
    assert output.startswith('DISK_MONITOR_TEST_MODE'), 'Self-test did not run'


def check(app, require_scanner=False):
    app = Path(app).resolve()
    if (app / 'Contents/Library/Scanner').exists():
        raise ValueError('Obsolete nested scanner app is not allowed')
    binaries = [app / 'Contents/MacOS' / name for name in ('Scanner', 'ScannerBridge')]
    has_scanner = any(path.exists() for path in binaries)
    if has_scanner and not all(path.is_file() and not path.is_symlink() for path in binaries):
        raise ValueError('Incomplete internal scanner package')
    if require_scanner and not has_scanner:
        raise ValueError('Release requires the signed scanner; refusing a scanner-less app')
    info = plistlib.loads((app / 'Contents/Info.plist').read_bytes())
    assert info['CFBundleIdentifier'] == IDENTIFIER
    assert info['LSMinimumSystemVersion'] == '15.0'
    assert info['SURequireSignedFeed'] is True and info['SUVerifyUpdateBeforeExtraction'] is True
    assert info['SUEnableSystemProfiling'] is False
    assert (app/'Contents/Frameworks/Sparkle.framework').is_dir()
    assert (app/'Contents/Resources/SPARKLE-LICENSE').is_file()
    subprocess.run(['codesign', '--verify', '--deep', '--strict', str(app)], check=True)
    check_release_binary(app)
    if has_scanner:
        from scanner_constraint import check as check_constraint
        check_constraint(app)
        subprocess.run([str(app / 'Contents/MacOS' / BINARY), '--scanner-package-self-test'], check=True, timeout=30)
        subprocess.run([str(binaries[1]), '--bundle-self-test'], check=True, timeout=10)
        for signed in binaries:
            signature = subprocess.run(['codesign', '-d', '--verbose=4', str(signed)], capture_output=True, text=True, check=True)
            assert '(runtime)' in signature.stderr, 'Scanner code must retain hardened runtime'
            entitlements = subprocess.run(['codesign', '-d', '--entitlements', ':-', str(signed)], capture_output=True, text=True, check=True)
            assert 'disable-library-validation' not in entitlements.stdout, 'Scanner library validation must stay enabled'
    if BINARY == 'TokenMonitor':
        resources = app / 'Contents/Resources'
        python = resources / 'python/bin/python3'
        assert python.is_file(), 'Bundled Python is required; system Python is not a distribution dependency'
        with tempfile.TemporaryDirectory(prefix='token-monitor-package-check-') as directory:
            home = Path(directory) / 'home'
            home.mkdir()
            raw = subprocess.check_output([str(python), '-B', '-E', '-s', str(resources / 'collector.py'), '--home', str(home), '--state', str(Path(directory) / 'state')], timeout=60)
            result = json.loads(raw)
            assert result['rows'] == [] and result['activeChildren'] == []
            assert all(not source['available'] for source in result['sources'])
            assert (Path(directory) / 'state/usage-v1.sqlite').is_file()
        print('PASS: bundled Python runs the collector against isolated empty sources')
    subprocess.run(['codesign', '--verify', '--deep', '--strict', str(app)], check=True)
    print('PASS: ' + APP_NAME + ' ' + info['CFBundleShortVersionString'] + ' package')

if __name__ == '__main__':
    arguments = sys.argv[1:]
    if arguments[:1] == ['--test-build'] and len(arguments) == 2:
        check_test_build(arguments[1])
    elif arguments and not arguments[0].startswith('-') and arguments[1:] in ([], ['--require-scanner']):
        check(arguments[0], require_scanner=arguments[1:] == ['--require-scanner'])
    else:
        sys.exit('usage: check_app.py <release app> [--require-scanner] | --test-build <test app>')
