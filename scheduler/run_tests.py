#!/usr/bin/env python3
"""Run tests on all completed MCP experiments for gpt-5."""
import json, glob, os, subprocess, re, time

RESULTS_DIR = '/root/experiments/results_mcp'
DATA_DIR = '/root/experiments/data_mcp'
TEST_SCRIPT = '/root/test_server.sh'
SMART_RUN = '/root/experiments/smart_run.sh'
SCORES_FILE = '/root/experiments/test_scores_mcp.jsonl'

LANGS = ['python', 'javascript', 'python-mypy', 'typescript', 'java', 'go', 'scala', 'rust', 'c']

with open(SCORES_FILE, 'w') as f:
    pass

count = 0
total = 0

for lang in LANGS:
    for rf in glob.glob(f'{RESULTS_DIR}/gpt-5/{lang}/rep*.json'):
        r = json.load(open(rf))
        if r.get('status') == 'completed':
            total += 1

print(f'Testing {total} completed MCP experiments', flush=True)

for lang in LANGS:
    for rf in sorted(glob.glob(f'{RESULTS_DIR}/gpt-5/{lang}/rep*.json')):
        r = json.load(open(rf))
        if r.get('status') != 'completed':
            continue

        rep_name = os.path.basename(rf).replace('.json', '')
        rep_num = int(rep_name.replace('rep', ''))
        workdir = f'{DATA_DIR}/gpt-5/{lang}/{rep_name}'
        run_script = f'{workdir}/run.sh'

        count += 1

        if not os.path.exists(run_script):
            print(f'[{count}/{total}] gpt-5/{lang}/{rep_name} ... no run.sh', flush=True)
            with open(SCORES_FILE, 'a') as f:
                f.write(json.dumps({'model': 'gpt-5', 'language': lang, 'rep': rep_num, 'passed': 0, 'total': 53, 'error': 'no_run_sh'}) + '\n')
            continue

        print(f'[{count}/{total}] gpt-5/{lang}/{rep_name} ... ', end='', flush=True)

        timeout_secs = 120 if lang in ('haskell', 'scala', 'rust', 'c', 'go') else 60

        try:
            result = subprocess.run(
                ['bash', TEST_SCRIPT, f'bash {SMART_RUN} {run_script}'],
                capture_output=True, text=True, timeout=timeout_secs,
                cwd=workdir
            )
            output = result.stdout + result.stderr
        except subprocess.TimeoutExpired:
            output = ''
            print('TIMEOUT, ', end='', flush=True)

        passed = len(re.findall(r'^ok \d+', output, re.MULTILINE))
        failed = len(re.findall(r'^not ok \d+', output, re.MULTILINE))
        test_total = passed + failed

        print(f'{passed}/{test_total}', flush=True)

        entry = {'model': 'gpt-5', 'language': lang, 'rep': rep_num, 'passed': passed, 'total': test_total}
        if test_total == 0:
            entry['error'] = 'server_fail'
        with open(SCORES_FILE, 'a') as f:
            f.write(json.dumps(entry) + '\n')

        subprocess.run(['pkill', '-f', 'server.*--port'], capture_output=True)
        subprocess.run(['pkill', '-f', 'todo.*--port'], capture_output=True)
        subprocess.run(['pkill', '-f', 'bloop'], capture_output=True)
        subprocess.run(['pkill', '-f', 'sbt'], capture_output=True)
        time.sleep(1)

print(f'\nALL TESTS DONE - {SCORES_FILE}', flush=True)
