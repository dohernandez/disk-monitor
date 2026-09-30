#!/usr/bin/env python3
"""Prepare the pinned Sparkle signing tools and the public-key update verifier.

Usage:
  python3 taskfiles/release/scripts/prepare_tools.py --dir DIR
  python3 taskfiles/release/scripts/prepare_tools.py --dir DIR --verifier-only

Options:
  --dir DIR          Output folder.
  --verifier-only    Only compile the verifier, to DIR/key_public (publish job; no Sparkle download).
                     Without it: checksum-verified Sparkle in DIR/sparkle, verifier in DIR/sparkle/key_public.

Project tooling (task release:tools); not part of the shipped app.
"""
import argparse
import json
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]
sys.path.insert(0, str(ROOT / 'taskfiles/build/scripts'))
import sparkle  # noqa: E402


def compile_verifier(output):
    # Same project-local CLT SwiftBridging overlay as build.sh; empty (a no-op) on
    # toolchains without the duplicate module map. System module maps are never changed.
    with tempfile.TemporaryDirectory(prefix='disk-monitor-verifier-') as directory:
        temporary = Path(directory)
        empty = temporary / 'empty.modulemap'
        empty.write_text('// Project-local compatibility overlay.\n')
        legacy = Path('/Library/Developer/CommandLineTools/usr/include/swift/module.modulemap')
        roots = ([{'type': 'file', 'name': str(legacy), 'external-contents': str(empty)}]
                 if legacy.exists() and legacy.with_name('bridging.modulemap').exists() else [])
        overlay = temporary / 'overlay.json'
        overlay.write_text(json.dumps({'version': 0, 'roots': roots}))
        subprocess.run(['xcrun', 'swiftc', '-vfsoverlay', str(overlay), '-Xcc', '-ivfsoverlay', '-Xcc', str(overlay),
                        '-module-cache-path', str(temporary / 'modules'),
                        str(ROOT / 'taskfiles/build/scripts/key_public.swift'), '-o', str(output)], check=True)
    return output


def main():
    parser = argparse.ArgumentParser(description='Prepare Sparkle signing tools and the update verifier.')
    parser.add_argument('--dir', required=True, type=Path)
    parser.add_argument('--verifier-only', action='store_true')
    args = parser.parse_args()
    directory = args.dir.resolve()
    directory.mkdir(parents=True, exist_ok=True)
    if args.verifier_only:
        print(compile_verifier(directory / 'key_public'))
    else:
        tools = sparkle.fetch(str(directory))
        compile_verifier(Path(tools) / 'key_public')
        print(tools)
    return 0


if __name__ == '__main__':
    sys.exit(main())
