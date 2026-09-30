#!/usr/bin/env python3
"""Check a commit message: a conventional-commit subject and no AI attribution (AGENTS.md; Darien, 2026-09-30).

Usage:
  python3 taskfiles/common/scripts/check_commit_message.py MSG_FILE
  python3 taskfiles/common/scripts/check_commit_message.py --attribution-only TEXT_FILE

Options:
  --attribution-only    Check only for AI attribution (PR descriptions have no subject line).

Run by the commit-msg git hook (pre-commit, stage commit-msg) and, through
check_pr_messages.py, by the CI policy job for commits made through the GitHub API.
Exit 0 when the text is valid, else 1 with the offending lines and the fix.

The attribution patterns match genlayer-node's check-commit-message.sh. They forbid
ATTRIBUTION, not naming a tool: there is no bare "AI" or "Claude" match, so a message
about the Claude observer, a human co-author or a CI [bot] co-author passes. Lines
starting with '#' are git comment text and are ignored.

Project tooling (task common:check:commit-message); not part of the shipped app.
"""

import argparse
import re
import sys
from pathlib import Path

TYPES = "build|chore|ci|docs|feat|fix|perf|refactor|revert|style|test"
SUBJECT = re.compile(rf"^({TYPES})(\([a-z0-9._/-]+\))?!?: \S.*$")
AI_ATTRIBUTION = [
    re.compile(
        r"Co-[Aa]uthored-[Bb]y:.*([Cc]laude|[Gg][Pp][Tt]|ChatGPT|[Cc]opilot|[Aa]nthropic|[Oo]pen[Aa][Ii]"
        r"|[Gg]emini|[Cc]ursor|[Ll]lama|[Dd]evin|[Cc]odex|devin-ai)"
    ),
    re.compile(r"noreply@(anthropic|openai)\."),
    re.compile(r"[Gg]enerated (by|with) .*([Cc]laude|[Aa]nthropic|[Gg][Pp][Tt]|[Cc]opilot|[Cc]ursor|ChatGPT|[Dd]evin)"),
    re.compile(r"[Cc]reated (by|with) .*([Cc]laude|[Gg][Pp][Tt]|[Cc]opilot|ChatGPT|[Dd]evin)"),
    re.compile("\N{ROBOT FACE}"),
]


def attribution(text: str) -> list:
    """Lines that attribute authorship to an AI tool."""
    lines = [ln for ln in text.splitlines() if not ln.startswith("#")]
    return [
        f"AI attribution is not allowed (AGENTS.md): '{ln.strip()}'; remove the line"
        for ln in lines
        if any(p.search(ln) for p in AI_ATTRIBUTION)
    ]


def check(text: str) -> list:
    lines = [ln for ln in text.splitlines() if not ln.startswith("#")]
    errors = []
    subject = lines[0] if lines else ""
    if not subject.startswith(("Merge ", 'Revert "', "fixup! ", "squash! ")):
        if not SUBJECT.match(subject):
            errors.append(
                f"subject '{subject}' is not a conventional commit: '<type>(<scope>)?: <summary>', type one of {TYPES}"
            )
        if len(subject) > 100:
            errors.append(f"subject is {len(subject)} characters; keep it at 100 or fewer")
    return errors + attribution(text)


def main() -> int:
    ap = argparse.ArgumentParser(description="Check a commit message or PR description.")
    ap.add_argument("--attribution-only", action="store_true")
    ap.add_argument("msg_file")
    a = ap.parse_args()
    text = Path(a.msg_file).read_text()
    errors = attribution(text) if a.attribution_only else check(text)
    for e in errors:
        print(f"commit message: {e}", file=sys.stderr)
    return 1 if errors else 0


if __name__ == "__main__":
    sys.exit(main())
