#!/usr/bin/env python3
"""Isolated preview build. Never registers, installs, launches, or edits trust settings.
Creates a self-signed test identity in its own private keychain, not the login keychain.
"""
import hashlib, json, os, plistlib, secrets, shlex, subprocess, sys
from pathlib import Path
SOURCE = Path(__file__).resolve().parent
BUILD_NUMBER = os.environ.get('PREVIEW_BUILD', '')
if not BUILD_NUMBER.isdecimal() or int(BUILD_NUMBER) < 1:
    raise SystemExit('Set PREVIEW_BUILD to an explicit positive, increasing build number.')
OUT = Path(sys.argv[1] if len(sys.argv) > 1 else '/tmp/disk-helper-preview-build').absolute()
OUT.mkdir(mode=0o700, parents=True, exist_ok=True)
if OUT.is_symlink() or OUT.stat().st_uid != os.getuid() or OUT.stat().st_mode & 0o077:
    raise SystemExit('Build directory must be owned by you, mode 0700 and not a link')
def run(args, **kw):
    p = subprocess.run(args, stdout=subprocess.PIPE, stderr=subprocess.PIPE, **kw)
    if p.returncode:
        # Arguments can contain temporary keychain passwords. Never echo them.
        raise RuntimeError(Path(args[0]).name + ' failed: ' + p.stderr.decode(errors='replace')[:1500])
    return p.stdout
identity = OUT / 'identity'
identity.mkdir(mode=0o700, exist_ok=True)
keychain = identity / 'preview.keychain-db'
cert = identity / 'certificate.der'
password_file = identity / 'keychain-password'
old_list = run(['/usr/bin/security', 'list-keychains', '-d', 'user']).decode()
if cert.exists() and not keychain.exists():
    raise SystemExit("This preview identity was retired. Use a new build directory; never silently rotate a registered helper identity.")
if not keychain.exists():
    password = secrets.token_urlsafe(32)
    fd = os.open(password_file, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    with os.fdopen(fd, 'w') as f: f.write(password)
    key, pem, p12 = (identity / n for n in ['temporary.key', 'certificate.pem', 'temporary.p12'])
    old_umask = os.umask(0o077)
    try:
        run(['/usr/bin/openssl', 'req', '-x509', '-newkey', 'rsa:3072', '-nodes', '-keyout', str(key), '-out', str(pem), '-days', '365', '-subj', '/CN=Disk Monitor Isolated Helper Preview/', '-addext', 'extendedKeyUsage=codeSigning', '-addext', 'keyUsage=digitalSignature'])
        run(['/usr/bin/openssl', 'x509', '-in', str(pem), '-outform', 'DER', '-out', str(cert)])
        run(['/usr/bin/openssl', 'pkcs12', '-export', '-inkey', str(key), '-in', str(pem), '-out', str(p12), '-passout', 'stdin'], input=(password + '\n').encode())
        run(['/usr/bin/security', 'create-keychain', '-p', password, str(keychain)])
        run(['/usr/bin/security', 'import', str(p12), '-k', str(keychain), '-P', password, '-T', '/usr/bin/codesign'])
        run(['/usr/bin/security', 'set-key-partition-list', '-S', 'apple-tool:,apple:', '-s', '-k', password, str(keychain)])
    finally:
        for f in [key, p12]:
            if f.exists(): f.unlink()
        os.umask(old_umask)
        # security create-keychain can add its new keychain to the search list.
        # Restore the exact original list, never make this identity globally trusted.
        current = run(['/usr/bin/security', 'list-keychains', '-d', 'user']).decode()
        if current != old_list:
            run(['/usr/bin/security', 'list-keychains', '-d', 'user', '-s', *shlex.split(old_list)])
password = password_file.read_text()
run(['/usr/bin/security', 'unlock-keychain', '-p', password, str(keychain)])
fingerprint = hashlib.sha1(cert.read_bytes()).hexdigest().upper()
(OUT / 'Identity.swift').write_text('let signingCertificateSHA1 = "' + fingerprint + '"\n')
legacy = Path('/Library/Developer/CommandLineTools/usr/include/swift/module.modulemap')
(OUT / 'empty.modulemap').write_text('// Local CLT overlay\n')
roots = [{'type': 'file', 'name': str(legacy), 'external-contents': str(OUT / 'empty.modulemap')}] if legacy.exists() and legacy.with_name('bridging.modulemap').exists() else []
(OUT / 'overlay.json').write_text(json.dumps({'version': 0, 'roots': roots}))
base = ['xcrun', 'swiftc', '-swift-version', '5', '-target', os.uname().machine + '-apple-macos15.0', '-parse-as-library', '-O', '-vfsoverlay', str(OUT / 'overlay.json'), '-Xcc', '-ivfsoverlay', '-Xcc', str(OUT / 'overlay.json'), '-module-cache-path', str(OUT / 'modules'), str(SOURCE / 'Shared.swift'), str(SOURCE / 'RequestState.swift'), str(OUT / 'Identity.swift')]
app = OUT / 'Disk Monitor Helper Preview 2.app'
macos = app / 'Contents/MacOS'; macos.mkdir(parents=True, exist_ok=True)
daemons = app / 'Contents/Library/LaunchDaemons'; daemons.mkdir(parents=True, exist_ok=True)
app_id = 'local.darien.diskmonitor.spotlight-preview2'
helper_id = app_id + '.scanner'
with (app / 'Contents/Info.plist').open('wb') as f:
    plistlib.dump({'CFBundleIdentifier': app_id, 'CFBundleName': 'Disk Monitor Helper Preview 2', 'CFBundleExecutable': 'Preview', 'CFBundlePackageType': 'APPL', 'CFBundleVersion': BUILD_NUMBER, 'LSMinimumSystemVersion': '15.0'}, f)
with (daemons / (helper_id + '.plist')).open('wb') as f:
    plistlib.dump({'Label': helper_id, 'BundleProgram': 'Contents/MacOS/Scanner', 'MachServices': {helper_id: True}, 'ProcessType': 'Background', 'AssociatedBundleIdentifiers': [app_id]}, f)
run([x for x in base if x != '-O'] + [str(SOURCE / 'Measurement.swift'), str(SOURCE / 'Tests.swift'), '-o', str(OUT / 'tests')])
print(run([str(OUT / 'tests')]).decode().strip())
run(base + [str(SOURCE / 'Measurement.swift'), str(SOURCE / 'Helper.swift'), '-o', str(macos / 'Scanner')])
run(base + [str(SOURCE / 'Client.swift'), '-framework', 'Cocoa', '-framework', 'ServiceManagement', '-o', str(macos / 'Preview')])
# codesign needs the certificate chain in its search list even with --keychain.
# Temporarily add only our isolated keychain; restore other concurrent changes too.
search_before = shlex.split(run(['/usr/bin/security', 'list-keychains', '-d', 'user']).decode())
was_present = str(keychain) in search_before
if not was_present:
    run(['/usr/bin/security', 'list-keychains', '-d', 'user', '-s', str(keychain), *search_before])
try:
    for path, identifier in [(macos / 'Scanner', helper_id), (app, app_id)]:
        run(['/usr/bin/codesign', '--force', '--options', 'runtime', '--timestamp=none', '--keychain', str(keychain), '--sign', fingerprint, '--identifier', identifier, str(path)])
        run(['/usr/bin/codesign', '--verify', '--strict', str(path)])
    run(['/usr/bin/codesign', '--verify', '--deep', '--strict', str(app)])
    print('Built and signature-verified:', app)
    print('Not installed, launched or registered. No trust settings changed.')
    
    # No root operations: authenticate a real anonymous XPC connection using a fixture service.
    auth = OUT / 'auth-tests'
    run([x for x in base if x != '-O'] + [str(SOURCE / 'AuthTests.swift'), '-o', str(auth)])
    run(['/usr/bin/codesign', '--force', '--options', 'runtime', '--timestamp=none', '--keychain', str(keychain), '--sign', fingerprint, '--identifier', app_id, str(auth)])
    print(run([str(auth)]).decode().strip())
finally:
    if not was_present:
        current = shlex.split(run(['/usr/bin/security', 'list-keychains', '-d', 'user']).decode())
        run(['/usr/bin/security', 'list-keychains', '-d', 'user', '-s', *[x for x in current if x != str(keychain)]])
