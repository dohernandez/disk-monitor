#!/usr/bin/env python3
"""Check a packaged app without opening its UI or reading real agent records."""
import json
import plistlib
import subprocess
import sys
import tempfile
from pathlib import Path
from bundle_info import APP_NAME, BINARY, IDENTIFIER


def check(app):
    app = Path(app).resolve()
    info = plistlib.loads((app / 'Contents/Info.plist').read_bytes())
    assert info['CFBundleIdentifier'] == IDENTIFIER
    assert info['LSMinimumSystemVersion'] == '15.0'
    subprocess.run(['codesign', '--verify', '--deep', '--strict', str(app)], check=True)
    subprocess.run([str(app / 'Contents/MacOS' / BINARY), '--self-test'], check=True, timeout=120)
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
    check(sys.argv[1])
