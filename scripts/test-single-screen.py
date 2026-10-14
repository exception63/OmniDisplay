#!/usr/bin/env python3
"""Subprocess contract tests. Every request has simulation=true; never calls CG mutation APIs."""
import json, os, pathlib, subprocess, tempfile, time, uuid
ROOT = pathlib.Path(__file__).resolve().parent.parent
HELPER = ROOT / 'dist.noindex/OmniDisplay.app/Contents/Helpers/OmniRecovery'

def read(path):
    try: return json.loads(path.read_text())
    except (FileNotFoundError, json.JSONDecodeError): return {}

def wait(dir, phases, timeout=8):
    end = time.monotonic() + timeout
    while time.monotonic() < end:
        receipt = read(dir/'receipt.json')
        if receipt.get('phase') in phases: return receipt
        time.sleep(.04)
    raise AssertionError(f'Timed out: {read(dir/"receipt.json")}')

def setup(parent, timeout=1):
    d = parent/str(uuid.uuid4()); d.mkdir()
    displays = [dict(id=f'00000000-0000-0000-0000-{i+1:012d}', displayID=i+1, name='同型号屏幕', active=True, main=i==0, builtin=False, mirrored=False, vendor=610, model=1, serial=i, x=i*1920, y=0, width=1920, height=1080, pixelWidth=3840, pixelHeight=2160, refresh=60, rotation=0) for i in range(4)]
    snap = dict(version=1, date=time.time()-978307200, boot='simulation', displays=displays)
    req = dict(version=1, nonce=str(uuid.uuid4()), operation='remote', before=snap, office=snap, keep=displays[0]['id'], confirmedPhysical=True, simulation=True, timeout=timeout)
    (d/'request.json').write_text(json.dumps(req)); return d

def launch(d): return subprocess.Popen([str(HELPER), '--transaction', str(d)], stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)
def marker(d, name): (d/name).touch()
def complete(p):
    p.wait(timeout=8)
    assert p.returncode == 0, p.stderr.read().decode()


results=[]
with tempfile.TemporaryDirectory(prefix='omni-single-tests-') as tmp:
    base=pathlib.Path(tmp)
    def single(action, timeout=1):
        d=setup(base,timeout); r=read(d/'request.json'); r['operation']=action; r['target']=r['before']['displays'][2]['id']; r['preserveLayout']=True
        if action=='connect': r['before']['displays'][2]['active']=False
        (d/'request.json').write_text(json.dumps(r)); return d,r
    d,r=single('disconnect'); p=launch(d); wait(d,['ready']); marker(d,'execute'); wait(d,['restored']); complete(p)
    assert read(d/'simulated-displays.json')==r['before']['displays']; results.append('PASS single disconnect timeout reconnects target')
    events=read(d/'events.json')
    assert [e['receipt']['phase'] for e in events]==['ready','awaitingConfirmation','restored']
    assert events[-1]['uptime']-events[-2]['uptime'] >= r['timeout']
    assert 'deadline' in events[-2]['receipt'] and '取消' in events[-1]['receipt']['message']
    results.append('PASS persisted phase history keeps deadline and restoration reason')
    d,r=single('disconnect',3); p=launch(d); wait(d,['ready']); marker(d,'execute'); wait(d,['awaitingConfirmation']); marker(d,'confirm'); wait(d,['confirmed']); complete(p)
    final=read(d/'simulated-displays.json'); assert not final[2]['active']
    for i in (0,1,3): assert final[i]==r['before']['displays'][i]
    results.append('PASS confirmed disconnect changes only selected screen')
    d,r=single('connect'); p=launch(d); wait(d,['ready']); marker(d,'execute'); wait(d,['restored']); complete(p)
    final=read(d/'simulated-displays.json'); assert final[2]['active']
    for i in (0,1,3): assert final[i]==r['before']['displays'][i]
    results.append('PASS reconnect targets offline screen and preserves peers')
    d,r=single('disconnect',3); p=launch(d); wait(d,['ready']); marker(d,'execute'); wait(d,['awaitingConfirmation']); marker(d,'cancel'); wait(d,['restored']); complete(p)
    assert read(d/'simulated-displays.json')==r['before']['displays']; results.append('PASS cancel reconnects selected screen')
    d,r=single('connect'); p=launch(d); wait(d,['ready']); marker(d,'cancel'); wait(d,['restored']); complete(p)
    assert not (d/'simulated-displays.json').exists(); results.append('PASS cancel before connection has no change')
    d,r=single('disconnect',3); p=launch(d); wait(d,['ready']); marker(d,'execute'); wait(d,['awaitingConfirmation'])
    current=read(d/'simulated-displays.json'); peer=dict(current[0]); peer['id']=str(uuid.uuid4()); peer['displayID']=99; peer['main']=False
    current.append(peer); current[0]['x']=-300
    (d/'simulated-displays.json').write_text(json.dumps(current)); marker(d,'cancel'); wait(d,['restored']); complete(p)
    final=read(d/'simulated-displays.json'); assert final[-1]==peer and final[0]['x']==-300 and final[2]['active']
    results.append('PASS target rollback preserves hotplugged and moved peers')
    d,r=single('disconnect'); r['confirmedPhysical']=False; (d/'request.json').write_text(json.dumps(r))
    p=launch(d); wait(d,['ready']); marker(d,'execute'); wait(d,['failed']); p.wait(timeout=5)
    assert p.returncode!=0 and not (d/'simulated-displays.json').exists()
    results.append('PASS helper rejects missing retained physical confirmation')
print('\n'.join(results)); print(f'{len(results)} single-screen integration checks passed; all simulation')
