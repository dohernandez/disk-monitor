#!/usr/bin/env python3
"""Repository rulesets as code: committed JSON snapshots <-> live GitHub rulesets.

Usage:
  python3 taskfiles/devtools/scripts/sync_rulesets.py export
  python3 taskfiles/devtools/scripts/sync_rulesets.py diff
  python3 taskfiles/devtools/scripts/sync_rulesets.py apply --validated-ref REF
  python3 taskfiles/devtools/scripts/sync_rulesets.py remove --name "EXACT NAME"

Commands:
  export    Write every live ruleset to taskfiles/devtools/rulesets/<slug>.json
            (normalized: name, target, enforcement, conditions, bypass_actors, rules).
  diff      Compare live rulesets with the snapshots; exit 2 on any drift.
  apply     Create or update live rulesets from the snapshots, then read each back.
            Never deletes. Refuses unless every required status check in the
            snapshots already passed on --validated-ref, so a rename can never leave
            PRs waiting for a check that no longer runs.
  remove    Delete one live ruleset by exact name and its snapshot.

Ported from genlayer-node's taskfiles/devtools/scripts/sync-rulesets.sh (Darien,
2026-09-30), plus the validated-ref guard. Changing a live ruleset is server-side:
apply and remove need Darien's approval. Needs `gh` (authenticated). Project tooling
(task devtools:rulesets:*); not part of the shipped app.

Exit codes:
  0 - success / no drift
  1 - prerequisite or argument error
  2 - drift detected (diff)
  3 - apply/remove refused or failed
"""
import argparse
import difflib
import json
import re
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]
RULESETS = ROOT / 'taskfiles/devtools/rulesets'
KEYS = ('name', 'target', 'enforcement', 'conditions', 'bypass_actors', 'rules')


def gh(*args, method=None, payload=None):
    command = ['gh', 'api', *args] + (['--method', method] if method else []) + (['--input', '-'] if payload is not None else [])
    result = subprocess.run(command, input=payload, capture_output=True, text=True, cwd=ROOT)
    if result.returncode != 0:
        raise RuntimeError('gh api %s failed: %s' % (args[0], result.stderr.strip()))
    return json.loads(result.stdout) if result.stdout.strip() else None


def repo():
    return subprocess.run(['gh', 'repo', 'view', '--json', 'nameWithOwner', '--jq', '.nameWithOwner'],
                          capture_output=True, text=True, check=True, cwd=ROOT).stdout.strip()


def slug(name):
    return re.sub(r'-+', '-', name.lower().replace(' ', '-').replace('(', '').replace(')', '')) + '.json'


def normalize(ruleset):
    return {key: ruleset.get(key) for key in KEYS}


def dump(ruleset):
    return json.dumps(normalize(ruleset), indent=2, sort_keys=True) + '\n'


def snapshots():
    return {json.loads(f.read_text())['name']: f for f in sorted(RULESETS.glob('*.json'))}


def live(name_of_repo):
    rulesets = gh('--paginate', 'repos/%s/rulesets' % name_of_repo)
    return {r['name']: gh('repos/%s/rulesets/%s' % (name_of_repo, r['id'])) for r in rulesets}


def required_checks(ruleset):
    return [c for rule in ruleset['rules'] if rule['type'] == 'required_status_checks'
            for c in rule['parameters']['required_status_checks']]


def export(name_of_repo):
    RULESETS.mkdir(parents=True, exist_ok=True)
    current = live(name_of_repo)
    for name, ruleset in current.items():
        path = RULESETS / slug(name)
        path.write_text(dump(ruleset))
        print("-> exported '%s' -> %s" % (name, path.relative_to(ROOT)))
    for name, path in snapshots().items():
        if name not in current:
            print("! snapshot %s has no live ruleset ('%s'); git rm it if intentional" % (path.relative_to(ROOT), name))
    print('exported %d ruleset(s). Review and commit the changes.' % len(current))
    return 0


def drift(name_of_repo):
    current, drifted = live(name_of_repo), 0
    for name, path in snapshots().items():
        if name not in current:
            print("x '%s': snapshot exists but no live ruleset (apply would create it)" % name)
            drifted = 1
        elif dump(current[name]) != path.read_text():
            print("x '%s': live ruleset drifted from %s" % (name, path.relative_to(ROOT)))
            sys.stdout.writelines('    ' + line for line in difflib.unified_diff(
                path.read_text().splitlines(True), dump(current[name]).splitlines(True), 'snapshot', 'live'))
            drifted = 1
        else:
            print("ok '%s': in sync" % name)
    for name in current:
        if name not in snapshots():
            print("x '%s': live ruleset has no snapshot; run export to capture it" % name)
            drifted = 1
    if drifted:
        print('drift detected: run devtools:rulesets:export and commit, or apply (with approval)', file=sys.stderr)
        return 2
    print('all rulesets in sync.')
    return 0


def apply(name_of_repo, ref):
    wanted = {name: json.loads(path.read_text()) for name, path in snapshots().items()}
    listing = subprocess.run(['gh', 'api', '--paginate', 'repos/%s/commits/%s/check-runs' % (name_of_repo, ref),
                              '--jq', '.check_runs[] | {name, conclusion, id, app: .app.id}'],
                             capture_output=True, text=True, check=True, cwd=ROOT).stdout
    runs = [json.loads(line) for line in listing.splitlines() if line.strip()]
    for name, ruleset in wanted.items():
        for check in required_checks(ruleset):
            matches = [r for r in runs if r['name'] == check['context'] and r['app'] == check.get('integration_id', r['app'])]
            if not matches or max(matches, key=lambda r: r['id'])['conclusion'] != 'success':
                print("refused: '%s' requires '%s', which has not passed on %s" % (name, check['context'], ref), file=sys.stderr)
                return 3
    current = {r['name']: r['id'] for r in gh('--paginate', 'repos/%s/rulesets' % name_of_repo)}
    for name, ruleset in wanted.items():
        body = json.dumps(ruleset)
        if name in current:
            saved = gh('repos/%s/rulesets/%s' % (name_of_repo, current[name]), method='PUT', payload=body)
        else:
            saved = gh('repos/%s/rulesets' % name_of_repo, method='POST', payload=body)
        if dump(gh('repos/%s/rulesets/%s' % (name_of_repo, saved['id']))) != dump(ruleset):
            print("x '%s': read-back differs from the snapshot; run diff" % name, file=sys.stderr)
            return 3
        print("-> %s '%s' (id %s), read back and matching" % ('updated' if name in current else 'created', name, saved['id']))
    print('apply complete. Live rulesets without snapshots are never deleted; use remove.')
    return 0


def remove(name_of_repo, name):
    current = {r['name']: r['id'] for r in gh('--paginate', 'repos/%s/rulesets' % name_of_repo)}
    path = RULESETS / slug(name)
    if name not in current and not path.exists():
        print("nothing named '%s' live or in %s" % (name, RULESETS.relative_to(ROOT)), file=sys.stderr)
        return 1
    if name in current:
        gh('repos/%s/rulesets/%s' % (name_of_repo, current[name]), method='DELETE')
        print("-> deleted live ruleset '%s'" % name)
    if path.exists():
        subprocess.run(['git', 'rm', '-q', str(path.relative_to(ROOT))], cwd=ROOT, check=True)
        print('-> removed snapshot %s (commit the deletion)' % path.relative_to(ROOT))
    return 0


def main():
    parser = argparse.ArgumentParser(description='Repository rulesets as code.')
    commands = parser.add_subparsers(dest='command', required=True)
    commands.add_parser('export')
    commands.add_parser('diff')
    applying = commands.add_parser('apply')
    applying.add_argument('--validated-ref', required=True, help='A ref where every required check already passed')
    removing = commands.add_parser('remove')
    removing.add_argument('--name', required=True, help='Exact ruleset name')
    args = parser.parse_args()
    name_of_repo = repo()
    if args.command == 'export':
        return export(name_of_repo)
    if args.command == 'diff':
        return drift(name_of_repo)
    if args.command == 'apply':
        return apply(name_of_repo, args.validated_ref)
    return remove(name_of_repo, args.name)


if __name__ == '__main__':
    sys.exit(main())
