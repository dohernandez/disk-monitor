"""Generate public scanner build constants. No keys or credentials in outputs."""
import json, os, re, sys
from pathlib import Path
out = Path(sys.argv[1])
identity = os.environ.get('SCANNER_SIGNING_SHA1', '')
if identity and not re.fullmatch(r'[0-9A-Fa-f]{40}', identity):
    raise SystemExit('SCANNER_SIGNING_SHA1 must be a public certificate SHA-1 fingerprint')
(out / 'ScannerIdentity.swift').write_text(
    'let signingCertificateSHA1 = ' + json.dumps(identity.upper()) + '\n'
    'let scannerBuildNumber = ' + json.dumps(os.environ.get('APP_BUILD', '1')) + '\n')
if identity:
    import plistlib
    host = out / 'Disk Monitor.app/Contents/Library/Scanner/Disk Monitor Scanner.app'
    daemon = host / 'Contents/Library/LaunchDaemons/local.darien.diskmonitor.scanner.service.plist'
    daemon.parent.mkdir(parents=True, exist_ok=True)
    with (host / 'Contents/Info.plist').open('wb') as f:
        plistlib.dump({'CFBundleIdentifier': 'local.darien.diskmonitor.scanner',
                      'CFBundleExecutable': 'Bridge', 'CFBundleName': 'Disk Monitor Scanner',
                      'CFBundlePackageType': 'APPL', 'CFBundleVersion': os.environ.get('APP_BUILD', '1'),
                      'LSMinimumSystemVersion': '15.0', 'LSUIElement': True}, f)
    with daemon.open('wb') as f:
        plistlib.dump({'Label': 'local.darien.diskmonitor.scanner.service',
                      'BundleProgram': 'Contents/MacOS/Scanner',
                      'MachServices': {'local.darien.diskmonitor.scanner.service': True},
                      'AssociatedBundleIdentifiers': ['local.darien.diskmonitor.scanner'],
                      'ProcessType': 'Background'}, f)
