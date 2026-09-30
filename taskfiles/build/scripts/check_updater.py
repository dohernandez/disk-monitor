"""Start Sparkle in a disposable identity of a test build (TEST_BUILD=1), without checks, windows or installation."""
import argparse
import plistlib
import shutil
import subprocess
import tempfile
import uuid
from pathlib import Path
from check_app import TEST_MODE_MARKERS, test_markers

def check(app):
    app=Path(app)
    assert len(test_markers(app))==len(TEST_MODE_MARKERS),'Needs a test build (task build:app -- --test); release builds have no --updater-self-test'
    with tempfile.TemporaryDirectory(prefix='monitor-updater-test-') as directory:
        fixture=Path(directory)/'Fixture.app';contents=fixture/'Contents';contents.mkdir(parents=True)
        shutil.copytree(app/'Contents/MacOS',contents/'MacOS')
        subprocess.run(['ditto',str(app/'Contents/Frameworks'),str(contents/'Frameworks')],check=True)
        info=plistlib.loads((app/'Contents/Info.plist').read_bytes())
        identity='local.monitor.updater-test.'+str(uuid.uuid4())
        info.update(CFBundleIdentifier=identity,SUEnableAutomaticChecks=False,SUAutomaticallyUpdate=False)
        (contents/'Info.plist').write_bytes(plistlib.dumps(info))
        subprocess.run(['codesign','--force','--sign','-',str(fixture)],check=True,capture_output=True)
        try:
            subprocess.run([str(contents/'MacOS'/info['CFBundleExecutable']),'--updater-self-test'],check=True,timeout=20)
        finally:
            subprocess.run(['defaults','delete',identity],capture_output=True)

if __name__=='__main__':
    parser=argparse.ArgumentParser(description='Start the embedded updater of a test build in a disposable identity.')
    parser.add_argument('app')
    check(parser.parse_args().app)
