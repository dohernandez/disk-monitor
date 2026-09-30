#!/usr/bin/env python3
"""Write validated bundle metadata; keep identity and preference domains stable."""
import plistlib
import json
import platform
import re
import sys
from pathlib import Path

APP_NAME = 'Disk Monitor'
BINARY = 'DiskMonitor'
IDENTIFIER = 'local.darien.diskmonitor'

def write_info(app, version, build):
    if not re.fullmatch(r"(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)", version):
        raise ValueError("Expected a numeric major.minor.patch version")
    if not re.fullmatch(r"[1-9][0-9]*", build):
        raise ValueError("Build number must be a positive integer")
    contents = Path(app) / "Contents"
    contents.mkdir(parents=True, exist_ok=True)
    data = dict(CFBundleExecutable=BINARY, CFBundleIdentifier=IDENTIFIER,
        CFBundleName=APP_NAME, CFBundleVersion=build, CFBundleShortVersionString=version,
        LSUIElement=True, NSHighResolutionCapable=True, LSMinimumSystemVersion="15.0")
    config = json.loads(Path(__file__).with_name('update-config.json').read_text())
    architecture = platform.machine()
    if architecture not in ('arm64', 'x86_64'): raise ValueError('Unsupported update architecture')
    data.update(SUFeedURL='https://github.com/'+config['repository']+'/releases/latest/download/appcast-'+architecture+'.xml',
        SUPublicEDKey=config['public_key'], SURequireSignedFeed=True,
        SUVerifyUpdateBeforeExtraction=True, SUEnableAutomaticChecks=False,
        SUAutomaticallyUpdate=False, SUAllowsAutomaticUpdates=True,
        SUScheduledCheckInterval=86400, SUEnableSystemProfiling=False, SUSendProfileInfo=False)
    (contents / "Info.plist").write_bytes(plistlib.dumps(data))

if __name__ == "__main__":
    write_info(*sys.argv[1:])
