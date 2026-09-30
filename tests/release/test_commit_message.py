"""The commit-msg and CI attribution checks: AI attribution fails; people, bots and tool names pass."""
import pathlib
import sys
_ROOT = pathlib.Path(__file__).resolve().parents[2]
sys.path[:0] = [str(_ROOT / 'taskfiles/common/scripts')]
import unittest
from check_commit_message import attribution, check
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

    def test_pr_description_only_checks_attribution(self):
        items = [('abc1234', 'fix: a change', True), ('PR #1 description', 'Free prose, no conventional subject.', False)]
        self.assertEqual(failures(items), [])
        items.append(('PR #2 description', 'Body\n\N{ROBOT FACE} Generated with Claude Code', False))
        self.assertEqual(len(failures(items)), 1)


if __name__ == '__main__':
    unittest.main()
