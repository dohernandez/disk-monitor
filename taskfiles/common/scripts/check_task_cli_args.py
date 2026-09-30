#!/usr/bin/env python3
"""Check that no task drops `-- --flag`: every task that runs a flag-parsing command must pass {{.CLI_ARGS}}.

Usage:
  python3 taskfiles/common/scripts/check_task_cli_args.py

For each task, `task --dry <task> -- <probe>` prints the commands Task would run; the probe must reach them.
Task ignores CLI_ARGS that no command consumes and still exits 0, so a dropped flag is silent without this
check (genlayer-node's check-task-cli-args.sh, docs/reviews/2026-09-29-taskfile-conventions-node-3.md).

Project tooling (task common:check:task-cli-args); not part of the shipped app.
"""

import argparse
import json
import subprocess
import sys

PROBE = "--check-task-cli-args-probe"
# Aggregate tasks only call other tasks; each child is checked on its own.
EXEMPT = {
    "common:test": "aggregate of the fast tests",
    "common:check": "aggregate of the checks",
    "provision:setup-dev": "aggregate of the install tasks",
    "provision:install-ruff": "installs a pinned tool; takes no flags",
    "provision:install-precommit": "installs a pinned tool; takes no flags",
    "provision:configure-precommit": "installs the git hooks; takes no flags",
}


def main() -> int:
    ap = argparse.ArgumentParser(description="Check that every task passes {{.CLI_ARGS}} on.")
    ap.parse_args()
    listing = subprocess.run(["task", "--list-all", "--json"], capture_output=True, text=True, check=True)
    tasks = [t["name"] for t in json.loads(listing.stdout)["tasks"]]
    bad = 0
    for name in tasks:
        if name in EXEMPT:
            continue
        dry = subprocess.run(["task", "--dry", name, "--", PROBE], capture_output=True, text=True)
        if PROBE not in dry.stdout + dry.stderr:
            print(f"FAIL  {name}: `-- {PROBE}` does not reach its command (add {{{{.CLI_ARGS}}}} last)")
            bad += 1
    print(f"{len(tasks) - len([t for t in tasks if t in EXEMPT])} tasks checked, {bad} drop CLI_ARGS")
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main())
