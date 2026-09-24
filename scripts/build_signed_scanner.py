#!/usr/bin/env python3
"""Main-only release build. Credentials exist only in a disposable CI keychain."""
import base64
import os
from pathlib import Path
import re
import secrets
import shlex
import subprocess
import tempfile


def release_inputs(env):
    if env.get('GITHUB_ACTIONS') != 'true' or env.get('GITHUB_REF') != 'refs/heads/main' or env.get('GITHUB_EVENT_NAME') not in ('push', 'workflow_dispatch'):
        raise ValueError('Scanner release signing requires a trusted main release job')
    fingerprint = env.get('SCANNER_SIGNING_SHA1', '')
    if not re.fullmatch('[0-9A-Fa-f]{40}', fingerprint):
        raise ValueError('A stable public scanner certificate fingerprint is required')
    password = env.get('SCANNER_P12_PASSWORD', '')
    if not password:
        raise ValueError('Scanner certificate password is missing')
    try:
        certificate = base64.b64decode(env.get('SCANNER_P12_BASE64', ''), validate=True)
    except ValueError:
        raise ValueError('Scanner certificate encoding is invalid') from None
    if not certificate or len(certificate) > 65536:
        raise ValueError('Scanner certificate is missing or exceeds its size limit')
    return fingerprint.upper(), password, certificate


def main():
    fingerprint, password, certificate = release_inputs(os.environ)
    env = {k: v for k, v in os.environ.items() if k not in ('SCANNER_P12_BASE64', 'SCANNER_P12_PASSWORD', 'SPARKLE_PRIVATE_KEY')}
    def security(*args):
        result = subprocess.run(['/usr/bin/security', *args], env=env, capture_output=True)
        if result.returncode:
            # Never print an exception containing password-bearing command arguments.
            raise RuntimeError('Temporary scanner keychain operation failed')
        return result.stdout.decode()
    previous = shlex.split(security('list-keychains', '-d', 'user'))
    with tempfile.TemporaryDirectory(prefix='scanner-signing-', dir=os.environ['RUNNER_TEMP']) as directory:
        root = Path(directory)
        p12 = root / 'certificate.p12'
        p12.write_bytes(certificate); p12.chmod(0o600)
        keychain = str(root / 'release.keychain-db')
        keychain_password = secrets.token_urlsafe(32)
        try:
            security('create-keychain', '-p', keychain_password, keychain)
            security('set-keychain-settings', '-lut', '1800', keychain)
            security('unlock-keychain', '-p', keychain_password, keychain)
            security('import', str(p12), '-k', keychain, '-P', password, '-T', '/usr/bin/codesign')
            p12.unlink()
            security('set-key-partition-list', '-S', 'apple-tool:,apple:,codesign:', '-s', '-k', keychain_password, keychain)
            security('list-keychains', '-d', 'user', '-s', *previous, keychain)
            # Self-signed identities need not chain to a globally trusted root.
            # Match the exact key pair; codesign and the package's pinned requirement
            # verify its use without changing certificate trust settings.
            identities = security('find-identity', '-p', 'codesigning', keychain)
            if fingerprint not in identities.upper():
                raise RuntimeError('Scanner signing identity does not match the configured public fingerprint')
            env['SCANNER_SIGNING_SHA1'] = fingerprint
            subprocess.run(['sh', 'build.sh'], env=env, check=True)
        finally:
            try:
                security('list-keychains', '-d', 'user', '-s', *previous)
            finally:
                if Path(keychain).exists():
                    security('delete-keychain', keychain)


if __name__ == '__main__':
    main()
