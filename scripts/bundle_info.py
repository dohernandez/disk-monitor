#!/usr/bin/env python3
"""Write validated bundle metadata; keep identity and preference domains stable."""
import plistlib
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
    (contents / "Info.plist").write_bytes(plistlib.dumps(data))

if __name__ == "__main__":
    write_info(*sys.argv[1:])
