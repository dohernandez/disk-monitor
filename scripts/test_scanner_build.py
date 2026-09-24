"""No keys, registration, system settings or real folder scans."""
import os
from pathlib import Path
import plistlib
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch
from types import SimpleNamespace

from package import package
import build_signed_scanner
from build_signed_scanner import release_inputs

class ScannerBuildTests(unittest.TestCase):
    def test_signing_cleanup_on_import_and_build_failure(self):
        for failure in ('import', 'build'):
            with self.subTest(failure=failure), tempfile.TemporaryDirectory() as directory:
                env = {'GITHUB_ACTIONS': 'true', 'GITHUB_REF': 'refs/heads/main', 'GITHUB_EVENT_NAME': 'push',
                       'RUNNER_TEMP': directory, 'SCANNER_SIGNING_SHA1': 'A' * 40,
                       'SCANNER_P12_PASSWORD': 'fixture-password', 'SCANNER_P12_BASE64': 'Zml4dHVyZQ=='}
                calls = []
                def execute(args, **kwargs):
                    calls.append(args)
                    self.assertNotIn('SCANNER_P12_PASSWORD', kwargs['env'])
                    self.assertNotIn('SCANNER_P12_BASE64', kwargs['env'])
                    if args[0] == 'sh':
                        raise subprocess.CalledProcessError(1, ['sh', 'build.sh'])
                    if args[1] == 'create-keychain':
                        Path(args[-1]).touch()
                    if args[1:] == ['list-keychains', '-d', 'user']:
                        return SimpleNamespace(returncode=0, stdout=b'"/fixture/original.keychain-db"\n')
                    if args[1] == 'find-identity':
                        return SimpleNamespace(returncode=0, stdout=('A' * 40).encode())
                    return SimpleNamespace(returncode=int(failure == 'import' and args[1] == 'import'), stdout=b'')
                with patch.dict(os.environ, env, clear=True), patch.object(build_signed_scanner.subprocess, 'run', side_effect=execute):
                    with self.assertRaises((RuntimeError, subprocess.CalledProcessError)):
                        build_signed_scanner.main()
                self.assertEqual(calls[-2], ['/usr/bin/security', 'list-keychains', '-d', 'user', '-s', '/fixture/original.keychain-db'])
                self.assertEqual(calls[-1][1], 'delete-keychain')
                self.assertEqual(list(Path(directory).iterdir()), [])

    def test_signing_ref_and_credentials_fail_closed(self):
        env = {'GITHUB_ACTIONS': 'true', 'GITHUB_REF': 'refs/heads/main', 'GITHUB_EVENT_NAME': 'push',
               'SCANNER_SIGNING_SHA1': 'A' * 40, 'SCANNER_P12_PASSWORD': 'fixture', 'SCANNER_P12_BASE64': 'Zml4dHVyZQ=='}
        self.assertEqual(release_inputs(env), ('A' * 40, 'fixture', b'fixture'))
        for key, value in [('GITHUB_ACTIONS', ''), ('GITHUB_REF', 'refs/pull/12/merge'),
                           ('GITHUB_EVENT_NAME', 'pull_request_target'), ('SCANNER_SIGNING_SHA1', 'invalid'),
                           ('SCANNER_P12_PASSWORD', ''), ('SCANNER_P12_BASE64', ''), ('SCANNER_P12_BASE64', '***')]:
            with self.subTest(key=key, value=value), self.assertRaises(ValueError):
                release_inputs({**env, key: value})
    def test_identity_modes_and_fixed_metadata(self):
        script = Path(__file__).with_name('scanner_identity.py')
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            def generate(identity):
                return subprocess.run([sys.executable, str(script), directory],
                                      env={**os.environ, 'SCANNER_SIGNING_SHA1': identity}, capture_output=True)
            self.assertEqual(generate('').returncode, 0)
            self.assertFalse((root / 'Disk Monitor.app').exists())
            self.assertNotEqual(generate('invalid').returncode, 0)
            self.assertFalse((root / 'Disk Monitor.app').exists())
            self.assertEqual(generate('A' * 40).returncode, 0)
            config = root / 'Disk Monitor.app/Contents/Library/Scanner/Disk Monitor Scanner.app/Contents/Library/LaunchDaemons/local.darien.diskmonitor.scanner.service.plist'
            value = plistlib.loads(config.read_bytes())
            self.assertEqual(value['BundleProgram'], 'Contents/MacOS/Scanner')
            self.assertEqual(value['MachServices'], {'local.darien.diskmonitor.scanner.service': True})
            self.assertNotIn('ProgramArguments', value)

    def test_release_packager_cannot_erase_scanner_identity(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            app = root / 'Fixture.app'
            executable = app / 'Contents/MacOS/Scanner'
            executable.parent.mkdir(parents=True)
            executable.write_text('fixture only')
            with self.assertRaisesRegex(ValueError, 'pinned signature'):
                package(app, '1.0.0', '1', root / 'out')
            self.assertFalse((root / 'out').exists())

if __name__ == '__main__':
    unittest.main()
