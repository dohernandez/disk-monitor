"""No keys, registration, system settings or real folder scans."""
import os
from pathlib import Path
import plistlib
import shutil
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch
from types import SimpleNamespace

from package import package
from check_app import check
import build_signed_scanner
from build_signed_scanner import release_inputs

class ScannerBuildTests(unittest.TestCase):
    def test_internal_client_has_identity_distinct_from_retired_app(self):
        root = Path(__file__).resolve().parents[1]
        shared = (root / 'HelperPrototype/Shared.swift').read_text()
        build = (root / 'build.sh').read_text()
        self.assertIn('static let appID = "local.darien.diskmonitor.scanner.client"', shared)
        self.assertIn('--identifier local.darien.diskmonitor.scanner.client ', build)
        self.assertNotIn('SpotlightAccess.swift', build)
        self.assertFalse((root / 'SpotlightAccess.swift').exists())
        self.assertNotIn('NSWindow', (root / 'PrivilegedFolderReader.swift').read_text())

    def test_release_rejects_missing_scanner_before_running_app(self):
        with tempfile.TemporaryDirectory() as directory:
            with patch('check_app.subprocess.run') as execute:
                with self.assertRaisesRegex(ValueError, 'Release requires the signed scanner'):
                    check(Path(directory) / 'Disk Monitor.app', require_scanner=True)
                execute.assert_not_called()

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
            config = root / 'Disk Monitor.app/Contents/Library/LaunchDaemons/local.darien.diskmonitor.scanner.service.plist'
            value = plistlib.loads(config.read_bytes())
            self.assertEqual(value['BundleProgram'], 'Contents/MacOS/Scanner')
            self.assertEqual(value['MachServices'], {'local.darien.diskmonitor.scanner.service': True})
            self.assertNotIn('ProgramArguments', value)
            self.assertEqual(value['AssociatedBundleIdentifiers'], ['local.darien.diskmonitor'])
            self.assertFalse((root / 'Disk Monitor.app/Contents/Library/Scanner').exists())

    def test_signed_release_rejects_restamping_before_staging(self):
        with tempfile.TemporaryDirectory() as directory:
            app = Path(directory) / 'Fixture.app'
            (app / 'Contents/MacOS').mkdir(parents=True)
            (app / 'Contents/MacOS/Scanner').touch()
            (app / 'Contents/Info.plist').write_bytes(plistlib.dumps({
                'CFBundleShortVersionString': '1.2.3', 'CFBundleVersion': '52'}))
            for version, build in [('1.2.4', '52'), ('1.2.3', '53')]:
                with patch('package.check'), patch('package.subprocess.run') as execute:
                    with self.assertRaisesRegex(ValueError, 'final version and build'):
                        package(app, version, build, Path(directory) / 'out', require_scanner=True)
                    execute.assert_not_called()
            self.assertFalse((Path(directory) / 'out').exists())

    def test_signed_release_preserves_all_bundle_bytes_without_signer(self):
        with tempfile.TemporaryDirectory() as directory:
            app = Path(directory) / 'Fixture.app'
            (app / 'Contents/MacOS').mkdir(parents=True)
            (app / 'Contents/MacOS/Scanner').write_bytes(b'fixture executable')
            (app / 'Contents/Info.plist').write_bytes(plistlib.dumps({
                'CFBundleShortVersionString': '1.2.3', 'CFBundleVersion': '52'}))
            (app / 'Contents/_CodeSignature').mkdir()
            (app / 'Contents/_CodeSignature/CodeResources').write_bytes(b'fixture seal')
            staged = None
            def execute(args, **kwargs):
                nonlocal staged
                if args[0] == 'ditto':
                    shutil.copytree(args[1], args[2]); staged = Path(args[2]).parent
                elif args[:2] == ['hdiutil', 'create']:
                    Path(args[-1]).write_bytes(b'fixture image')
                elif args[:2] == ['hdiutil', 'attach']:
                    shutil.copytree(staged, Path(args[args.index('-mountpoint') + 1]), dirs_exist_ok=True, symlinks=True)
                else:
                    self.assertIn(args[:2], [['hdiutil', 'verify'], ['hdiutil', 'detach']])
            def verify(candidate, **kwargs):
                for source in app.rglob('*'):
                    if source.is_file():
                        self.assertEqual((candidate / source.relative_to(app)).read_bytes(), source.read_bytes())
            with patch('package.check', side_effect=verify), patch('package.subprocess.run', side_effect=execute), patch('package.write_info') as write_info:
                image = package(app, '1.2.3', '52', Path(directory) / 'out', require_scanner=True)
                self.assertTrue(image.is_file())
                write_info.assert_not_called()

    def test_release_packager_cannot_erase_scanner_identity(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            app = root / 'Fixture.app'
            executable = app / 'Contents/MacOS/Scanner'
            executable.parent.mkdir(parents=True)
            executable.write_text('fixture only')
            with self.assertRaisesRegex(ValueError, 'Incomplete internal scanner'):
                package(app, '1.0.0', '1', root / 'out')
            self.assertFalse((root / 'out').exists())

if __name__ == '__main__':
    unittest.main()
