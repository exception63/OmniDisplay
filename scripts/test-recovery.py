#!/usr/bin/env python3
"""Subprocess contract tests. Every request has simulation=true; never calls CG mutation APIs."""
import json, os, pathlib, subprocess, tempfile, time, uuid
ROOT = pathlib.Path(__file__).resolve().parent.parent
HELPER = ROOT / 'dist/OmniDisplay.app/Contents/Helpers/OmniRecovery'

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
    req = dict(version=1, nonce=d.name, operation='remote', before=snap, office=snap, keep=displays[0]['id'], confirmedPhysical=True, simulation=True, timeout=timeout)
    (d/'request.json').write_text(json.dumps(req)); return d

def launch(d): return subprocess.Popen([str(HELPER), '--transaction', str(d)], stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)
def marker(d, name): (d/name).touch()
def complete(p):
    p.wait(timeout=8)
    assert p.returncode == 0, p.stderr.read().decode()

results=[]
with tempfile.TemporaryDirectory(prefix='omni-recovery-tests-') as tmp:
    base=pathlib.Path(tmp)
    # Timeout restores while no GUI is present.
    d=setup(base); p=launch(d); wait(d, ['ready']); marker(d,'execute'); wait(d,['restored']); complete(p)
    assert (d/'simulated-applied.json').exists() and (d/'simulated-restored.json').exists()
    results.append('PASS timeout restores four-screen snapshot without UI')
    # Confirmation keeps remote and stops helper.
    d=setup(base, 3); p=launch(d); wait(d,['ready']); marker(d,'execute'); wait(d,['awaitingConfirmation']); marker(d,'confirm'); wait(d,['confirmed']); complete(p)
    assert not (d/'simulated-restored.json').exists(); results.append('PASS explicit confirmation keeps single-screen mode')
    # Cancellation has precedence over confirmation.
    d=setup(base, 3); p=launch(d); wait(d,['ready']); marker(d,'execute'); wait(d,['awaitingConfirmation']); marker(d,'cancel'); marker(d,'confirm'); wait(d,['restored']); complete(p)
    results.append('PASS cancel wins over simultaneous confirmation')
    # Canceled before apply means absolutely no mutation.
    d=setup(base); p=launch(d); wait(d,['ready']); marker(d,'cancel'); wait(d,['restored']); complete(p)
    assert not (d/'simulated-applied.json').exists(); results.append('PASS preflight cancellation has no mutation')
    # A duplicate click/process cannot race the active worker.
    d=setup(base, 3); p=launch(d); wait(d,['ready']); d2=setup(base); p2=launch(d2); wait(d2,['failed']); p2.wait(timeout=3)
    assert not (d2/'simulated-applied.json').exists(); marker(d,'cancel'); complete(p)
    results.append('PASS concurrent operations rejected by process lock')
    # Physical panel confirmation is mandatory even in simulation.
    d=setup(base); req=read(d/'request.json'); req['confirmedPhysical']=False; (d/'request.json').write_text(json.dumps(req)); p=launch(d); wait(d,['ready']); marker(d,'execute'); wait(d,['failed']); p.wait(timeout=3)
    assert not (d/'simulated-applied.json').exists(); results.append('PASS missing physical-panel acknowledgment rejected')
    # Restore operation uses office snapshot and never enters disable path.
    d=setup(base); req=read(d/'request.json'); req['operation']='restore'; (d/'request.json').write_text(json.dumps(req)); p=launch(d); wait(d,['ready']); marker(d,'execute'); wait(d,['restored']); complete(p)
    assert not (d/'simulated-applied.json').exists(); results.append('PASS restore takes enable-only path')
    # Helper survives abrupt death of its launching parent.
    d=setup(base)
    code='import subprocess,time; p=subprocess.Popen('+repr([str(HELPER),'--transaction',str(d)])+'); print(p.pid,flush=True); time.sleep(30)'
    parent=subprocess.Popen(['python3','-c',code],stdout=subprocess.PIPE)
    worker_pid=int(parent.stdout.readline()); wait(d,['ready']); marker(d,'execute'); wait(d,['awaitingConfirmation']); parent.kill(); parent.wait(timeout=3)
    wait(d,['restored']); assert (d/'simulated-restored.json').exists()
    results.append('PASS helper survives killed UI parent and rolls back')
print('\n'.join(results)); print(f'{len(results)} integration checks passed; no real display mutations')
