#!/usr/bin/env python3
"""Apply this repo's main ruleset after checks pass; never alter visibility or billing."""
import argparse
import json
import subprocess
from pathlib import Path


def api(path, *args):
    return json.loads(subprocess.check_output(['gh', 'api', path, *args], text=True))

def apply(ref):
    root = Path(__file__).resolve().parents[1]
    repo = json.loads(subprocess.check_output(['gh','repo','view','--json','nameWithOwner'],cwd=root,text=True))['nameWithOwner']
    specification = root / '.github/main-ruleset.json'
    rules = json.loads(specification.read_text())
    expected = next(r['parameters']['required_status_checks'] for r in rules['rules'] if r['type']=='required_status_checks')
    checks = api('repos/'+repo+'/commits/'+ref+'/check-runs')['check_runs']
    for expected_check in expected:
        matches = [c for c in checks if c['name']==expected_check['context'] and c['app']['id']==expected_check['integration_id']]
        if not matches or max(matches, key=lambda c:c['id'])['conclusion'] != 'success':
            raise RuntimeError('Required check must first pass: '+expected_check['context'])
    existing = [r for r in api('repos/'+repo+'/rulesets') if r['name']==rules['name']]
    if len(existing)>1:
        raise RuntimeError('Multiple matching rulesets; inspect before changing them')
    endpoint='repos/'+repo+'/rulesets'
    if existing:
        endpoint += '/'+str(existing[0]['id'])
    response=api(endpoint,'--method','PUT' if existing else 'POST','--input',str(specification))
    saved=api('repos/'+repo+'/rulesets/'+str(response['id']))
    assert saved['enforcement']=='active'
    for rule in rules['rules']:
        matching = next(r for r in saved['rules'] if r['type']==rule['type'])
        for key,value in rule.get('parameters',{}).items():
            assert matching['parameters'][key]==value
    assert saved['conditions']==rules['conditions'] and not saved['bypass_actors']
    print(saved['_links']['html']['href'])

if __name__=='__main__':
    parser=argparse.ArgumentParser()
    parser.add_argument('--validated-ref',default='main',help='A ref whose required checks have passed')
    apply(parser.parse_args().validated_ref)
