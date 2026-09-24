"""Validate nested scanner identity continuity; never installs or registers."""
from pathlib import Path
import subprocess
import sys

relative = 'Contents/Library/Scanner/Disk Monitor Scanner.app'
subprocess.run([sys.executable, str(Path(__file__).resolve().parents[1] / 'HelperPrototype/verify_replacement.py'),
                str(Path(sys.argv[1]) / relative), str(Path(sys.argv[2]) / relative)], check=True)
