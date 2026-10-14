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
with tempfile.TemporaryDirectory(prefix='omni-input-tests-') as tmp:
    base=pathlib.Path(tmp)
    def input_request(timeout=1):
        d=setup(base,timeout); r=read(d/'request.json'); r.update(operation='inputSource',target=r['before']['displays'][1]['id'],inputBefore=17,inputAfter=15)
        (d/'request.json').write_text(json.dumps(r)); return d,r
    d,r=input_request(); p=launch(d); wait(d,['ready']); marker(d,'execute'); wait(d,['restored']); complete(p)
    assert read(d/'simulated-inputs.json')[r['target']]==17; results.append('PASS input timeout restores original input')
    d,r=input_request(3); p=launch(d); wait(d,['ready']); marker(d,'execute'); wait(d,['awaitingConfirmation']); marker(d,'confirm'); wait(d,['confirmed']); complete(p)
    assert read(d/'simulated-inputs.json')[r['target']]==15; results.append('PASS confirmed input change persists')
    d,r=input_request(3); p=launch(d); wait(d,['ready']); marker(d,'execute'); wait(d,['awaitingConfirmation'])
    inputs=read(d/'simulated-inputs.json'); inputs['new-peer']=18; (d/'simulated-inputs.json').write_text(json.dumps(inputs))
    marker(d,'cancel'); marker(d,'confirm'); wait(d,['restored']); complete(p)
    assert read(d/'simulated-inputs.json')=={r['target']:17,'new-peer':18}; results.append('PASS input cancel wins and preserves peers')
    d,r=input_request(); p=launch(d); wait(d,['ready']); marker(d,'cancel'); wait(d,['restored']); complete(p)
    assert not (d/'simulated-inputs.json').exists(); results.append('PASS cancel before execute has no input change')
    d,r=input_request(); r['keep']=r['target']; (d/'request.json').write_text(json.dumps(r))
    p=launch(d); wait(d,['ready']); marker(d,'execute'); wait(d,['failed']); p.wait(timeout=5)
    assert not (d/'simulated-inputs.json').exists(); results.append('PASS cannot switch sole retained input')
print('\n'.join(results)); print(f'{len(results)} input integration checks passed; all simulation')
