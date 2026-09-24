#!/usr/bin/env python3
"""Create and verify a drag-to-Applications DMG without installing the app."""
import argparse
import hashlib
import platform
import subprocess
import tempfile
from pathlib import Path
from bundle_info import APP_NAME, write_info
from check_app import check


def package(app, version, build, output, require_scanner=False):
    app, output = Path(app).resolve(), Path(output).resolve()
    if (app / 'Contents/MacOS/Scanner').exists():
        raise ValueError('Scanner-enabled release packaging is not accepted yet; refusing to replace its pinned signature with ad-hoc signing')
    output.mkdir(parents=True, exist_ok=True)
    architecture = platform.machine()
    if architecture not in ('arm64', 'x86_64'):
        raise ValueError('Unsupported Mac architecture')
    destination = output / (APP_NAME.replace(' ', '-') + '-' + version + '-macOS-' + architecture + '.dmg')
    if destination.exists():
        raise FileExistsError('Refusing to overwrite an existing installer: ' + str(destination))
    with tempfile.TemporaryDirectory(prefix='monitor-package-') as directory:
        temporary = Path(directory)
        image = temporary / destination.name
        stage = temporary / 'stage'
        stage.mkdir()
        staged_app = stage / (APP_NAME + '.app')
        subprocess.run(['ditto', str(app), str(staged_app)], check=True)
        write_info(staged_app, version, build)
        subprocess.run(['codesign', '--force', '--sign', '-', str(staged_app)], check=True)
        check(staged_app, require_scanner=require_scanner)
        (stage / 'Applications').symlink_to('/Applications', target_is_directory=True)
        (stage / 'Install.txt').write_text(
            APP_NAME + ' ' + version + '\n\n'
            'Requires macOS 15 or later. Choose arm64 for Apple Silicon, x86_64 for Intel.\n'
            'Quit any existing copy, then drag the app into Applications and launch it there.\n'
            'The app appears in the menu bar. Command-drag its icon to choose a position.\n'
            'Settings and saved measurements stay in your user account when replacing the app.\n\n'
            'This build is ad-hoc signed, not Apple Developer ID-signed or notarized.\n'
            'macOS may block a downloaded copy. See the repository installation guide.\n'
            'There is no automatic login item, cleanup, or agent configuration change.\n')
        subprocess.run(['hdiutil', 'create', '-volname', APP_NAME + ' ' + version, '-srcfolder', str(stage), '-format', 'UDZO', str(image)], check=True)
        subprocess.run(['hdiutil', 'verify', str(image)], check=True)
        mount = temporary / 'mounted'
        mount.mkdir()
        attached = False
        try:
            subprocess.run(['hdiutil', 'attach', '-readonly', '-nobrowse', '-mountpoint', str(mount), str(image)], check=True)
            attached = True
            assert (mount / 'Applications').is_symlink()
            assert (mount / 'Applications').readlink() == Path('/Applications')
            check(mount / (APP_NAME + '.app'), require_scanner=require_scanner)
        finally:
            if attached:
                subprocess.run(['hdiutil', 'detach', str(mount)], check=True)
        image.replace(destination)
    image = destination
    digest = hashlib.sha256(image.read_bytes()).hexdigest()
    image.with_suffix('.dmg.sha256').write_text(digest + '  ' + image.name + '\n')
    print(image)
    return image

if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('--app', required=True)
    parser.add_argument('--version', required=True)
    parser.add_argument('--build', default='1')
    parser.add_argument('--output', default='dist')
    parser.add_argument('--require-scanner', action='store_true')
    args = parser.parse_args()
    package(args.app, args.version, args.build, args.output, require_scanner=args.require_scanner)
