#!/usr/bin/env python3
"""omnidisplay 命令行 → 模拟版 App 的端到端检查（用户 2026-10-21 授权 agent 直接执行）。
只起 OmniDisplay Simulation.app（独立 bundle、临时数据目录、--agent 不弹窗），真实屏幕不变。
先跑 scripts/build.sh --simulation。"""
import json, os, pathlib, plistlib, subprocess, sys, tempfile, time, uuid

ROOT = pathlib.Path(__file__).resolve().parent.parent
APP = ROOT / 'dist.noindex/OmniDisplay Simulation.app'
CLI = APP / 'Contents/Helpers/omnidisplay'
KEY = plistlib.loads((APP / 'Contents/Info.plist').read_bytes())['CFBundleIdentifier'] + '.demo'
MAILBOX = pathlib.Path.home() / 'Library/Application Support/OmniDisplay/Agent' / KEY

def run(*args):
    p = subprocess.run([str(CLI), *args, '--json'], capture_output=True, text=True, timeout=180)
    try: body = json.loads(p.stdout)
    except json.JSONDecodeError: body = {'ok': False, 'message': p.stderr.strip()}
    return p.returncode, body

def states(body): return [(s['number'], s['connected'], s['main']) for s in body['screens']]

results = []
def check(name, cond, detail=''):
    results.append(('PASS ' if cond else 'FAIL ') + name + ('' if cond else f' :: {detail}'))

with tempfile.TemporaryDirectory(prefix='omni-agent-tests-') as tmp:
    app = subprocess.Popen([str(APP / 'Contents/MacOS/OmniDisplay'), '--demo', '4', '--data-dir', tmp, '--agent'],
                           stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    try:
        time.sleep(2)
        code, body = run('list')
        check('list 4 screens left to right, #1 main', code == 0 and states(body) == [(1, True, True), (2, True, False), (3, True, False), (4, True, False)], body)

        code, body = run('disconnect', '1')
        check('main screen refused', code == 1 and '主屏' in body['message'] and all(s['connected'] for s in body['screens']), body)

        code, body = run('disconnect', '9')
        check('out of range refused', code == 1 and '1–4' in body['message'], body)

        code, body = run('disconnect', '3')
        check('disconnect #3 kept automatically', code == 0 and body.get('phase') == 'confirmed', body)
        check('numbers stay: #3 offline, #4 still #4', [s['connected'] for s in body['screens']] == [True, True, False, True], body)

        code, body = run('disconnect', '3')
        check('repeat disconnect is a no-op', code == 0 and '已经断开' in body['message'], body)

        code, body = run('connect', '3')
        check('connect #3', code == 0 and body.get('phase') == 'restored' and all(s['connected'] for s in body['screens']), body)

        code, body = run('mode', 'remote')
        check('remote mode keeps only main', code == 0 and [s['connected'] for s in body['screens']] == [True, False, False, False], body)

        code, body = run('connect', 'all')
        check('connect all = office mode', code == 0 and all(s['connected'] for s in body['screens']), body)

        code, body = run('mode', 'office')
        check('office again is a no-op', code == 0 and '已经是办公室模式' in body['message'], body)

        code, body = run('rotate', '2', 'right')
        check('rotate #2 clockwise kept', code == 0 and body.get('phase') == 'confirmed', body)

        # 过期请求：App 不执行，只回绝。
        stale = {'id': str(uuid.uuid4()), 'command': 'disconnect', 'number': 4,
                 'createdAt': time.strftime('%Y-%m-%dT%H:%M:%SZ', time.gmtime(time.time() - 60))}
        (MAILBOX / 'requests' / f'0-{stale["id"]}.json').write_text(json.dumps(stale))
        answer = MAILBOX / 'responses' / f'{stale["id"]}.json'
        for _ in range(40):
            if answer.exists(): break
            time.sleep(0.1)
        reply = json.loads(answer.read_text()) if answer.exists() else {}
        answer.unlink(missing_ok=True)
        check('stale request rejected, not executed', reply.get('ok') is False and '过期' in reply.get('message', '') and all(s['connected'] for s in reply.get('screens', [])), reply)

        code, body = run('save-layout')
        check('save-layout with all connected', code == 0, body)

        txs = list(pathlib.Path(tmp, 'Simulation/Transactions').glob('*/request.json'))
        check('every transaction is marked origin=agent', txs and all(json.loads(t.read_text()).get('origin') == 'agent' for t in txs), len(txs))
    finally:
        app.terminate(); app.wait(timeout=10)

for line in results: print(line)
sys.exit(0 if all(r.startswith('PASS') for r in results) else 1)
