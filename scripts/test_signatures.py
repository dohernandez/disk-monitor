"""Real Sparkle/CryptoKit checks using disposable signing seeds, never release keys."""
import base64
import os
import subprocess
import tempfile
import unittest
from pathlib import Path
from bundle_info import APP_NAME
from sign_release import sign_release
from verify_release import verify_assets

@unittest.skipUnless(os.environ.get('SPARKLE_TOOLS'), 'Run after build with SPARKLE_TOOLS set')
class SignatureTests(unittest.TestCase):
    def test_signed_release_and_rejected_tampering(self):
        tools=Path(os.environ['SPARKLE_TOOLS']);verifier=tools/'key_public'
        seed=base64.b64encode(os.urandom(32))
        public=subprocess.check_output([str(verifier)],input=seed).decode().strip()
        config=dict(repository='fixture/monitor',public_key=public)
        with tempfile.TemporaryDirectory() as directory:
            image=Path(directory)/(APP_NAME.replace(' ','-')+'-1.1.0-macOS-arm64.dmg');image.write_bytes(b'fixture installer')
            feed=sign_release(image,'1.1.0','12','arm64',tools,seed,config)
            original=feed.read_bytes()
            verify_assets(image,feed,'1.1.0',config,verifier)
            image.write_bytes(b'fixture installeX')
            with self.assertRaisesRegex(ValueError,'signature'):verify_assets(image,feed,'1.1.0',config,verifier)
            image.write_bytes(b'fixture installer')
            feed.write_bytes(original.replace(b'1.1.0',b'9.9.9'))
            with self.assertRaises(ValueError):verify_assets(image,feed,'1.1.0',config,verifier)
            feed.write_bytes(original.split(b'<!-- sparkle-signatures:')[0])
            with self.assertRaisesRegex(ValueError,'signed feed'):verify_assets(image,feed,'1.1.0',config,verifier)
            feed.write_bytes(original)
            wrong=base64.b64encode(os.urandom(32))
            with self.assertRaisesRegex(ValueError,'does not match'):sign_release(image,'1.1.0','12','arm64',tools,wrong,config)
            with self.assertRaisesRegex(ValueError,'does not match'):verify_assets(image,feed,'1.2.0',config,verifier)
            other=dict(config,public_key=subprocess.check_output([str(verifier)],input=wrong).decode().strip())
            with self.assertRaisesRegex(ValueError,'signature'):verify_assets(image,feed,'1.1.0',other,verifier)

if __name__=='__main__':
    if not os.environ.get('SPARKLE_TOOLS'):raise SystemExit('SPARKLE_TOOLS is required for signature verification tests')
    unittest.main()
