#!/usr/bin/env python3
"""Publish only complete installer sets; published releases remain immutable."""
import hashlib
import json
import os
import subprocess
from pathlib import Path
from bundle_info import APP_NAME


def publish():
    tag = os.environ['RELEASE_TAG']
    version = tag.removeprefix('v')
    dist = Path('dist')
    assets = []
    for arch in ('arm64', 'x86_64'):
        image = dist / (APP_NAME.replace(' ', '-') + '-' + version + '-macOS-' + arch + '.dmg')
        checksum = image.with_suffix('.dmg.sha256')
        expected = hashlib.sha256(image.read_bytes()).hexdigest() + '  ' + image.name + '\n'
        if checksum.read_text() != expected:
            raise ValueError('Installer checksum mismatch: ' + image.name)
        assets.extend([image, checksum])
    result = subprocess.run(['gh','release','view',tag,'--json','isDraft,url'],text=True,capture_output=True)
    if result.returncode == 0:
        previous = json.loads(result.stdout)
        if not previous['isDraft']:
            print('Already published; preserving existing release: ' + previous['url'])
            return
    else:
        notes = dist / 'release-notes.md'
        notes.write_text(
            '## Install\n\nDownload **arm64** for Apple Silicon or **x86_64** for Intel (macOS 15+). '
            'Open the DMG, quit any older copy, and drag the app into Applications. '
            'Existing preferences and local records are preserved.\n\n'
            '**Signing:** these downloads are ad-hoc signed, not Apple Developer ID-signed or notarized. '
            'macOS may block downloaded copies; see docs/RELEASING.md for installation and signing status.\n\n'
            'SHA-256 checksums accompany both installers. '
            'No login item or agent settings are changed during installation.\n\n'
            + ('Token Monitor includes Python. Claude quota observation is an optional, separate setup step; see docs/USAGE.md.\n\n' if APP_NAME=='Token Monitor' else '')
        )
        subprocess.run(['gh','release','create',tag,'--verify-tag','--draft','--title',APP_NAME+' '+tag,'--generate-notes','--notes-file',str(notes)],check=True)
    subprocess.run(['gh','release','upload',tag,*map(str,assets),'--clobber'],check=True)
    subprocess.run(['gh','release','edit',tag,'--draft=false'],check=True)
    subprocess.run(['gh','release','view',tag,'--json','url','--jq','.url'],check=True)

if __name__=='__main__':
    publish()
