"""Start Sparkle in a disposable app identity, without checks, windows or installation."""
import plistlib
import shutil
import subprocess
import sys
import tempfile
import uuid
from pathlib import Path

def check(app):
    app=Path(app)
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

if __name__=='__main__':check(sys.argv[1])
