import subprocess
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch
import release_version as release
import bundle_info

class ReleaseTests(unittest.TestCase):
    def test_first_release_is_stable(self):
        self.assertEqual(release.next_tag({}, 'feature/installers'), 'v1.0.0')
    def test_branch_versioning(self):
        for branch, expected in [('fix/icon', 'v1.2.4'), ('hotfix/icon', 'v1.2.4'), ('docs/readme', 'v1.2.4'), ('feat/alert', 'v1.3.0'), ('feature/alert', 'v1.3.0'), ('major/api', 'v2.0.0'), ('release/api', 'v2.0.0')]:
            with self.subTest(branch=branch):
                self.assertEqual(release.next_tag(['v1.2.3', 'v1.1.9', 'unrelated'], branch), expected)
    def test_semantic_sort_and_initial_floor(self):
        self.assertEqual(release.next_tag(['v1.9.9', 'v1.10.0'], 'fix/a'), 'v1.10.1')
        self.assertEqual(release.next_tag(['v0.1.0'], 'fix/a'), 'v1.0.0')
    def test_rerun_reuses_commit_tag_without_push(self):
        with patch.object(release, 'remote_tags', return_value={'v1.0.0': 'a'*40}), patch.object(release.subprocess, 'run') as push:
            self.assertEqual(release.reserve('a'*40, 'feature/a'), 'v1.0.0')
            push.assert_not_called()
    def test_conflicting_reservation_retries_without_force(self):
        with patch.object(release, 'remote_tags', side_effect=[{}, {'v1.0.0': 'b'*40}, {'v1.0.0': 'b'*40}]), patch.object(release.subprocess, 'run', side_effect=[subprocess.CompletedProcess([],1,'','tag exists'),subprocess.CompletedProcess([],0,'','')]) as push:
            self.assertEqual(release.reserve('a'*40, 'fix/a'), 'v1.0.1')
            self.assertEqual(push.call_args_list[0].args[0], ['git','push','origin','a'*40+':refs/tags/v1.0.0'])
            self.assertEqual(push.call_args_list[1].args[0], ['git','push','origin','a'*40+':refs/tags/v1.0.1'])
    def test_permission_failure_does_not_keep_allocating(self):
        with patch.object(release, 'remote_tags', return_value={}), patch.object(release.subprocess, 'run', return_value=subprocess.CompletedProcess([],1,'','permission denied')):
            with self.assertRaisesRegex(RuntimeError, 'permission denied'):
                release.reserve('a'*40, 'fix/a')
    def test_metadata_rejects_invalid_versions(self):
        with tempfile.TemporaryDirectory() as root:
            for version in ['v1.0.0', '../bad', '1.0', '1.0.0-preview', '01.0.0']:
                with self.subTest(version=version), self.assertRaises(ValueError):
                    bundle_info.write_info(root,version,'1')
            bundle_info.write_info(root,'1.0.0','12')
            import plistlib
            info=plistlib.loads((Path(root)/'Contents/Info.plist').read_bytes())
            self.assertEqual(info['CFBundleShortVersionString'],'1.0.0')
            self.assertEqual(info['LSMinimumSystemVersion'],'15.0')
            self.assertEqual(info['CFBundleIdentifier'],bundle_info.IDENTIFIER)

    def test_real_git_reservation_is_repeatable(self):
        import os
        with tempfile.TemporaryDirectory() as directory:
            base=Path(directory);remote=base/'remote.git';work=base/'work'
            def git(*args):
                return subprocess.check_output(['git',*args],stderr=subprocess.STDOUT,text=True)
            git('init','--bare','--initial-branch=main',str(remote))
            git('clone',str(remote),str(work))
            before=Path.cwd()
            try:
                os.chdir(work)
                (work/'file').write_text('one')
                git('add','file')
                git('-c','commit.gpgsign=false','-c','user.name=Fixture','-c','user.email=fixture@example.invalid','commit','-m','one')
                first=git('rev-parse','HEAD').strip();git('push','origin','main')
                self.assertEqual(release.reserve(first,'feature/first'),'v1.0.0')
                self.assertEqual(release.reserve(first,'feature/first'),'v1.0.0')
                (work/'file').write_text('two');git('add','file')
                git('-c','commit.gpgsign=false','-c','user.name=Fixture','-c','user.email=fixture@example.invalid','commit','-m','two')
                second=git('rev-parse','HEAD').strip();git('push','origin','main')
                self.assertEqual(release.reserve(second,'feature/next'),'v1.1.0')
                self.assertEqual(release.remote_tags(),{'v1.0.0':first,'v1.1.0':second})
            finally:
                os.chdir(before)

    def test_publish_requires_both_architectures_and_valid_checksums(self):
        import hashlib, os, publish_release
        with tempfile.TemporaryDirectory() as directory:
            before=Path.cwd()
            try:
                os.chdir(directory);Path('dist').mkdir()
                with patch.dict(os.environ,RELEASE_TAG='v1.0.0'), patch.object(publish_release.subprocess,'run') as gh:
                    with self.assertRaises(FileNotFoundError):publish_release.publish()
                    gh.assert_not_called()
                    for arch in ('arm64','x86_64'):
                        image=Path('dist')/(bundle_info.APP_NAME.replace(' ','-')+'-1.0.0-macOS-'+arch+'.dmg')
                        image.write_bytes(b'fixture')
                        image.with_suffix('.dmg.sha256').write_text(hashlib.sha256(b'fixture').hexdigest()+'  '+image.name+'\n')
                    image.with_suffix('.dmg.sha256').write_text('wrong')
                    with self.assertRaises(ValueError):publish_release.publish()
                    gh.assert_not_called()
            finally:os.chdir(before)

    def test_publish_uploads_before_undrafting_and_keeps_published_release(self):
        import hashlib, os, publish_release
        with tempfile.TemporaryDirectory() as directory:
            before=Path.cwd()
            try:
                os.chdir(directory);Path('dist').mkdir()
                for arch in ('arm64','x86_64'):
                    image=Path('dist')/(bundle_info.APP_NAME.replace(' ','-')+'-1.0.0-macOS-'+arch+'.dmg')
                    image.write_bytes(b'fixture')
                    image.with_suffix('.dmg.sha256').write_text(hashlib.sha256(b'fixture').hexdigest()+'  '+image.name+'\n')
                def result(args,**kwargs):
                    return subprocess.CompletedProcess(args,1 if args[1:3]==['release','view'] else 0,'','')
                with patch.dict(os.environ,RELEASE_TAG='v1.0.0'), patch.object(publish_release.subprocess,'run',side_effect=result) as gh:
                    publish_release.publish()
                    commands=[c.args[0] for c in gh.call_args_list]
                    self.assertIn('--draft',commands[1])
                    self.assertEqual(commands[2][1:3],['release','upload'])
                    self.assertEqual(commands[3],['gh','release','edit','v1.0.0','--draft=false'])
                published=subprocess.CompletedProcess([],0,'{"isDraft":false,"url":"https://example.invalid/release"}','')
                with patch.dict(os.environ,RELEASE_TAG='v1.0.0'), patch.object(publish_release.subprocess,'run',return_value=published) as gh:
                    publish_release.publish();self.assertEqual(gh.call_count,1)
            finally:os.chdir(before)

if __name__=='__main__':
    unittest.main()
