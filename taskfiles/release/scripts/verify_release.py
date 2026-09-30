"""Verify feed and installer signatures using only the committed public key."""
import re
import subprocess
import tempfile
import xml.etree.ElementTree as ET
from pathlib import Path

NS='http://www.andymatuschak.org/xml-namespaces/sparkle'

def verify_file(path, signature, public, verifier):
    result=subprocess.run([str(verifier),'--verify',str(path),public,signature],capture_output=True)
    if result.returncode:raise ValueError('Invalid update signature: '+Path(path).name)

def verify_assets(image, feed, version, config, verifier):
    raw=Path(feed).read_bytes()
    match=re.search(rb'<!-- sparkle-signatures:\nedSignature: ([A-Za-z0-9+/=]+)\nlength: ([0-9]+)\n-->\s*\Z',raw)
    if not match or int(match[2]) != match.start():raise ValueError('Missing or malformed signed feed')
    with tempfile.NamedTemporaryFile() as file:
        file.write(raw[:match.start()]);file.flush()
        verify_file(file.name,match[1].decode(),config['public_key'],verifier)
    root=ET.fromstring(raw);items=root.findall('./channel/item')
    if len(items)!=1:raise ValueError('Expected one release in the feed')
    item=items[0];enclosure=item.find('enclosure');image=Path(image)
    expected='https://github.com/'+config['repository']+'/releases/download/v'+version+'/'+image.name
    if (enclosure is None or enclosure.get('url')!=expected or enclosure.get('length')!=str(image.stat().st_size)
        or item.findtext('{'+NS+'}shortVersionString')!=version or not re.fullmatch(r'[1-9][0-9]*',item.findtext('{'+NS+'}version') or '')):
        raise ValueError('Feed does not match this installer and version')
    verify_file(image,enclosure.get('{'+NS+'}edSignature',''),config['public_key'],verifier)
