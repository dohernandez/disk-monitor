"""No keys, registration, system settings or real folder scans."""
import os
from pathlib import Path
import plistlib
import subprocess
import sys
import tempfile
import unittest

from package import package

class ScannerBuildTests(unittest.TestCase):
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
