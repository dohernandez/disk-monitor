#!/usr/bin/env python3
"""Sign the final DMG and its architecture-specific feed; never print key material."""
import argparse
import json
import os
import re
import subprocess
import xml.etree.ElementTree as ET
from pathlib import Path
from bundle_info import APP_NAME

NS = 'http://www.andymatuschak.org/xml-namespaces/sparkle'
ET.register_namespace('sparkle', NS)

def sign_release(image, version, build, arch, tools, seed, config):
    image=Path(image)
    if arch not in ('arm64','x86_64') or not re.fullmatch(r'[1-9][0-9]*',build) or not re.fullmatch(r'(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)',version):
        raise ValueError('Invalid update metadata')
    expected=APP_NAME.replace(' ','-')+'-'+version+'-macOS-'+arch+'.dmg'
    if image.name!=expected:raise ValueError('Installer name does not match release')
    public=subprocess.check_output([str(Path(tools)/'key_public')],input=seed).decode().strip()
    if public!=config['public_key']:raise ValueError('Signing key does not match the app public key')
    sign=Path(tools)/'bin/sign_update'
    signature=subprocess.check_output([str(sign),'--ed-key-file','-','-p',str(image)],input=seed).decode().strip()
    subprocess.run([str(sign),'--ed-key-file','-','--verify',str(image),signature],input=seed,check=True,capture_output=True)
    rss=ET.Element('rss',version='2.0');channel=ET.SubElement(rss,'channel')
    ET.SubElement(channel,'title').text=APP_NAME+' updates'
    item=ET.SubElement(channel,'item');ET.SubElement(item,'title').text=APP_NAME+' '+version
    ET.SubElement(item,'{'+NS+'}version').text=build
    ET.SubElement(item,'{'+NS+'}shortVersionString').text=version
    ET.SubElement(item,'{'+NS+'}minimumSystemVersion').text='15.0.0'
    ET.SubElement(item,'description').text='Signed update. Your existing preferences and saved measurements are preserved.'
    ET.SubElement(item,'enclosure',{'url':'https://github.com/'+config['repository']+'/releases/download/v'+version+'/'+image.name,
        'length':str(image.stat().st_size),'type':'application/octet-stream','{'+NS+'}edSignature':signature})
    feed=image.parent/('appcast-'+arch+'.xml')
    feed.write_bytes(ET.tostring(rss,encoding='utf-8',xml_declaration=True))
    subprocess.run([str(sign),'--ed-key-file','-',str(feed)],input=seed,check=True,capture_output=True)
    subprocess.run([str(sign),'--ed-key-file','-','--verify',str(feed)],input=seed,check=True,capture_output=True)
    return feed

if __name__=='__main__':
    parser=argparse.ArgumentParser();parser.add_argument('--image',required=True);parser.add_argument('--version',required=True);parser.add_argument('--build',required=True);parser.add_argument('--arch',required=True);parser.add_argument('--tools',required=True);a=parser.parse_args()
    seed=os.environ.pop('SPARKLE_PRIVATE_KEY','').encode()
    if not seed:raise SystemExit('SPARKLE_PRIVATE_KEY is required; unsigned releases are refused')
    config=json.loads(Path(__file__).with_name('update-config.json').read_text())
    feed=sign_release(a.image,a.version,a.build,a.arch,a.tools,seed,config)
    print('Signed installer and feed: '+feed.name)
