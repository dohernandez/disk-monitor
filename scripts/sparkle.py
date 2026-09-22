#!/usr/bin/env python3
"""Fetch and embed the exact reviewed Sparkle distribution, including licenses."""
import hashlib
import shutil
import subprocess
import sys
import tarfile
import tempfile
from pathlib import Path
from secure_archive import extract_archive

VERSION = '2.10.0'
SHA256 = 'c2bf58aa8387266ac179357b1415d6f2635f044da8be41042af32425dae6da0c'
URL = 'https://github.com/sparkle-project/Sparkle/releases/download/2.10.0/Sparkle-2.10.0.tar.xz'

def fetch(build):
    build = Path(build);build.mkdir(parents=True,exist_ok=True)
    archive = build/'Sparkle.tar.xz'
    if not archive.exists():
        with tempfile.NamedTemporaryFile(dir=build,delete=False) as file: download=Path(file.name)
        try:
            subprocess.run(['curl','--fail','--location','--proto','=https','--proto-redir','=https','--retry','3','--output',str(download),URL],check=True)
            if hashlib.sha256(download.read_bytes()).hexdigest()!=SHA256:raise ValueError('Sparkle checksum mismatch')
            download.replace(archive)
        finally:download.unlink(missing_ok=True)
    if hashlib.sha256(archive.read_bytes()).hexdigest()!=SHA256:raise ValueError('Cached Sparkle checksum mismatch')
    destination=build/'sparkle'
    # Re-extract the verified archive on each build; a stale extraction is not trusted.
    with tempfile.TemporaryDirectory(dir=build) as temporary:
        extract=Path(temporary)/'extract';extract.mkdir()
        with tarfile.open(archive) as file:extract_archive(file,extract)
        if destination.exists():shutil.rmtree(destination)
        shutil.move(str(extract),destination)
    return destination

if __name__=='__main__':
    print(fetch(sys.argv[1]))
