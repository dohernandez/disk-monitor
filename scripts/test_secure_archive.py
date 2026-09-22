import io
import tarfile
import unittest

class ExtractionTests(unittest.TestCase):
    def extract(self, entries, destination):
        from secure_archive import extract_archive
        data=io.BytesIO()
        with tarfile.open(fileobj=data,mode='w') as archive:
            for name, kind, value in entries:
                entry=tarfile.TarInfo(name);entry.type=kind
                if kind==tarfile.REGTYPE:
                    entry.size=len(value);archive.addfile(entry,io.BytesIO(value))
                else:
                    entry.linkname=value;archive.addfile(entry)
        data.seek(0)
        with tarfile.open(fileobj=data) as archive:extract_archive(archive,destination)

    def test_valid_relative_links(self):
        import tempfile
        from pathlib import Path
        with tempfile.TemporaryDirectory() as directory:
            self.extract([('python/bin/python3.12',tarfile.REGTYPE,b'runtime'),('python/bin/python3',tarfile.SYMTYPE,'python3.12')],directory)
            self.assertEqual((Path(directory)/'python/bin/python3').read_bytes(),b'runtime')

    def test_rejects_link_attacks_without_outside_writes(self):
        import tempfile
        from pathlib import Path
        attacks=[
            [('python/dir',tarfile.SYMTYPE,'.'),('python/link',tarfile.SYMTYPE,'dir/../outside'),('python/link',tarfile.REGTYPE,b'probe')],
            [('python/dir',tarfile.SYMTYPE,'.'),('python/dir/file',tarfile.REGTYPE,b'probe')],
            [('python/link',tarfile.LNKTYPE,'../outside')],
            [('python/a',tarfile.SYMTYPE,'b'),('python/b',tarfile.SYMTYPE,'a')],
            [('python/file',tarfile.REGTYPE,b'a'),('python/./file',tarfile.REGTYPE,b'b')],
            [('python/dir',tarfile.SYMTYPE,'.'),('python/link',tarfile.SYMTYPE,'dir/../outside')],
        ]
        for entries in attacks:
            with self.subTest(entries=entries),tempfile.TemporaryDirectory() as directory:
                root=Path(directory);destination=root/'extract';destination.mkdir();outside=root/'outside';outside.write_bytes(b'unchanged')
                with self.assertRaises(ValueError):self.extract(entries,destination)
                self.assertEqual(outside.read_bytes(),b'unchanged')
                self.assertFalse((destination/'outside').exists())
