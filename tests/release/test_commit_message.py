"""The commit-msg and CI attribution checks: AI attribution fails; people, bots and tool names pass."""
import pathlib
import sys
from pathlib import Path
_ROOT = pathlib.Path(__file__).resolve().parents[2]
sys.path[:0] = [str(_ROOT / 'taskfiles/common/scripts')]
import shutil
import subprocess
import tempfile
import unittest
from check_commit_message import attribution, check
SCRIPT = _ROOT / 'taskfiles/common/scripts/check_commit_message.py'
from check_pr_messages import failures


class CommitMessageTests(unittest.TestCase):
    def test_ai_attribution_fails(self):
        for trailer in ('Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>',
                        'Co-authored-by: GitHub Copilot <copilot@github.com>',
                        'Co-Authored-By: ChatGPT <x@example.com>',
                        'Co-authored-by: Devin <devin-ai-integration[bot]@users.noreply.github.com>',
                        'Signed-off: someone <noreply@openai.com>',
                        '\N{ROBOT FACE} Generated with [Claude Code](https://claude.com/claude-code)',
                        'Generated with Cursor',
                        'Created by GPT-5'):
            with self.subTest(trailer=trailer):
                self.assertTrue(check('fix: a change\n\nBody.\n\n' + trailer))
                self.assertTrue(attribution('Description.\n' + trailer))

    def test_people_bots_and_tool_names_pass(self):
        for message in ('fix: forward the Claude observer footer\n\nCo-authored-by: Ana Maria <ana@example.com>',
                        'chore: bump actions\n\nCo-authored-by: renovate[bot] <29139614+renovate[bot]@users.noreply.github.com>',
                        'feat: group Codex and OpenCode usage by subscription',
                        'docs: explain the AI quota reset countdown',
                        'fix: parse Claude Code session logs\n# Co-Authored-By: Claude (git comment line, stripped)'):
            with self.subTest(message=message):
                self.assertEqual(check(message), [])

    def test_subject_rules(self):
        self.assertTrue(check('Show pending updates'))
        self.assertTrue(check('fix: ' + 'x' * 100))
        self.assertEqual(check('Merge branch main into feature'), [])

    def test_attribution_scan_runs_for_merge_revert_fixup_squash(self):
        trailer = '\n\nCo-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>'
        for subject in ('Merge branch main into feature', 'Revert "fix: a change"', 'fixup! fix: a change', 'squash! fix: a change'):
            with self.subTest(subject=subject):
                self.assertEqual(check(subject), [], 'the subject rules may skip these')
                self.assertTrue(check(subject + trailer), 'the attribution scan never skips')

    def test_cli_rejects_unknown_flags_and_missing_files(self):
        with tempfile.TemporaryDirectory() as folder:
            message = Path(folder) / 'MSG'
            message.write_text('fix: a change\n')
            run = lambda *args: subprocess.run(['python3', str(SCRIPT), *args], capture_output=True, text=True)
            self.assertEqual(run(str(message)).returncode, 0)
            self.assertNotEqual(run('--no-such-flag', str(message)).returncode, 0)
            self.assertNotEqual(run(str(Path(folder) / 'missing')).returncode, 0)
            message.write_text('Free prose\n\N{ROBOT FACE} Generated with Claude Code\n')
            self.assertNotEqual(run('--attribution-only', str(message)).returncode, 0)
            message.write_text('Free prose, no conventional subject.\n')
            self.assertEqual(run('--attribution-only', str(message)).returncode, 0)

    def test_pr_description_only_checks_attribution(self):
        items = [('abc1234', 'fix: a change', True), ('PR #1 description', 'Free prose, no conventional subject.', False)]
        in_process = lambda text, full: check(text) if full else attribution(text)  # noqa: E731
        self.assertEqual(failures(items, in_process), [])
        items.append(('PR #2 description', 'Body\n\N{ROBOT FACE} Generated with Claude Code', False))
        self.assertEqual(len(failures(items, in_process)), 1)

    @unittest.skipUnless(shutil.which('task'), 'Task is not installed')
    def test_ci_runs_the_hook_task(self):
        """CI goes through `task common:check:commit-msg`, exactly like the commit-msg hook."""
        items = [('abc1234', 'fix: a change', True),
                 ('def5678', 'Merge branch main\n\nCo-Authored-By: Claude <noreply@anthropic.com>', True),
                 ('PR #3 description', 'Prose without a conventional subject.', False),
                 ('PR #4 description', 'Body\n\N{ROBOT FACE} Generated with Claude Code', False)]
        found = failures(items)
        self.assertEqual([f.split(':')[0] for f in found], ['def5678', 'PR #4 description'])


if __name__ == '__main__':
    unittest.main()
