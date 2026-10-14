#!/usr/bin/env python3
"""Mode owner lifecycle tests. All requests are explicitly simulation=true."""
import copy,json,pathlib,subprocess,tempfile,time,uuid,fcntl
ROOT=pathlib.Path(__file__).resolve().parent.parent
HELPER=ROOT/'dist.noindex/OmniDisplay.app/Contents/Helpers/OmniRecovery'
def read(p):
    try:return json.loads(p.read_text())
    except (FileNotFoundError,json.JSONDecodeError):return {}
def wait(d,phases,timeout=10):
    end=time.monotonic()+timeout
    while time.monotonic()<end:
        r=read(d/'receipt.json')
        if r.get('phase') in phases:return r
        time.sleep(.02)
    raise AssertionError(read(d/'receipt.json'))
def launch(d):
    assert read(d/'request.json')['simulation'] is True
    return subprocess.Popen([str(HELPER),'--transaction',str(d)],stdout=subprocess.DEVNULL,stderr=subprocess.PIPE)
def start(d):
    p=launch(d);wait(d,['ready']);(d/'execute').touch();return p
def done(p,success=True):
    p.wait(timeout=10);err=p.stderr.read().decode()
    assert (p.returncode==0)==success,err
    if success:assert not err,err
def setup(base,operation='remoteMode',entry=None,keep=0,timeout=.6):
    d=base/str(uuid.uuid4());d.mkdir()
    screens=[dict(id=f'00000000-0000-4000-8000-{i+1:012d}',displayID=i+1,name=f'Example {i}',active=True,main=i==0,builtin=False,mirrored=False,vendor=610,model=1,serial=i,x=i*1920,y=0,width=1920,height=1080,pixelWidth=3840,pixelHeight=2160,refresh=60,rotation=0) for i in range(4)]
    office=dict(version=1,date=0,boot='simulation',displays=screens)
    before=copy.deepcopy(office)
    if entry is not None:
        single=copy.deepcopy(screens[entry]);single.update(x=0,y=0,main=True);before['displays']=[single]
    r=dict(version=1,nonce=d.name,operation=operation,before=before,office=office,keep=screens[keep]['id'],target=screens[keep]['id'],confirmedPhysical=True,simulation=True,timeout=timeout)
    (d/'request.json').write_text(json.dumps(r));return d,r
results=[]
with tempfile.TemporaryDirectory(prefix='omni-modes-') as tmp:
    base=pathlib.Path(tmp)
    d,r=setup(base,timeout=3);original=(d/'request.json').read_bytes();p=start(d);wait(d,['awaitingConfirmation']);(d/'confirm').touch();wait(d,['confirmed']);done(p)
    assert [x['id'] for x in read(d/'simulated-displays.json')]==[r['keep']] and (d/'request.json').read_bytes()==original
    events=read(d/'events.json');assert sum(x['receipt']['phase']=='awaitingConfirmation' for x in events)==1
    results.append('PASS remote keeps selected screen, immutable office baseline and one confirmation timer')
    d,r=setup(base,entry=0,keep=2);p=start(d);wait(d,['restored']);done(p)
    assert read(d/'simulated-displays.json')==r['before']['displays'];results.append('PASS remote A to B timeout restores A, not four screens')
    d,r=setup(base,'officeMode',entry=2,timeout=3);p=start(d);wait(d,['awaitingConfirmation']);(d/'confirm').touch();wait(d,['confirmed']);done(p)
    assert read(d/'simulated-displays.json')==r['office']['displays'];results.append('PASS office restores full saved layout and primary')
    d,r=setup(base,'officeMode',entry=2,timeout=3);p=start(d);wait(d,['awaitingConfirmation']);(d/'cancel').touch();wait(d,['restored']);done(p)
    assert read(d/'simulated-displays.json')==r['before']['displays'];results.append('PASS cancelling office returns to its single-screen entry')
    d,r=setup(base);(d/'simulation-fail-step-1').touch();p=start(d);wait(d,['restored']);done(p)
    assert read(d/'simulated-displays.json')==r['before']['displays'];results.append('PASS mid-apply failure rolls back completed steps')
    d,r=setup(base);(d/'simulation-fail-step-1').touch();(d/'simulation-fail-rollback').touch();p=start(d);wait(d,['failed']);done(p)
    assert read(d/'simulated-displays.json') and read(d/'simulated-displays.json')!=r['before']['displays'];results.append('PASS rollback failure reports failed, never false success or zero screens')
    d,r=setup(base,timeout=3);p=start(d);wait(d,['awaitingConfirmation']);state=read(d/'simulated-displays.json');new=copy.deepcopy(state[0]);new.update(id=str(uuid.uuid4()),displayID=99,main=False,x=8000);state.append(new);(d/'simulated-displays.json').write_text(json.dumps(state));wait(d,['failed']);done(p)
    assert new in read(d/'simulated-displays.json');results.append('PASS hotplug uses enable-only recovery and preserves new hardware')
    d,r=setup(base,timeout=3);p=start(d);wait(d,['awaitingConfirmation']);state=read(d/'simulated-displays.json');state[0]['y']=13;(d/'simulated-displays.json').write_text(json.dumps(state));wait(d,['failed']);done(p)
    assert read(d/'simulated-displays.json')[0]['y']==13;results.append('PASS manual geometry is not overwritten by stale rollback')
    d,r=setup(base);p=launch(d);wait(d,['ready']);d2,r2=setup(base);p2=launch(d2);wait(d2,['failed']);done(p2,False);(d/'cancel').touch();wait(d,['restored']);done(p)
    assert not (d/'simulated-displays.json').exists() and not (d2/'simulated-displays.json').exists();results.append('PASS duplicate process serialized and cancel-before-execute has no mutation')
    d,r=setup(base,entry=0,keep=0);p=start(d);wait(d,['confirmed']);done(p)
    assert 'awaitingConfirmation' not in [e['receipt']['phase'] for e in read(d/'events.json')];results.append('PASS already-selected mode is idempotent')
    d,r=setup(base)
    code='import subprocess,time; p=subprocess.Popen('+repr([str(HELPER),'--transaction',str(d)])+'); print(p.pid,flush=True); time.sleep(30)'
    parent=subprocess.Popen(['python3','-c',code],stdout=subprocess.PIPE);parent.stdout.readline();wait(d,['ready']);(d/'execute').touch();wait(d,['awaitingConfirmation']);parent.kill();parent.wait(timeout=3);wait(d,['restored'])
    assert read(d/'simulated-displays.json')==r['before']['displays'];results.append('PASS owner countdown survives abrupt UI-parent exit')
    d,r=setup(base,timeout=3);p=start(d);wait(d,['awaitingConfirmation']);p.kill();p.wait(timeout=3)
    assert read(d/'request.json')['before']==r['before'] and (d/'mode-checkpoint.json').exists()
    with (base/'operation.lock').open('r') as f:fcntl.flock(f,fcntl.LOCK_EX|fcntl.LOCK_NB);fcntl.flock(f,fcntl.LOCK_UN)
    assert read(d/'receipt.json')['phase']=='awaitingConfirmation';results.append('PASS interrupted owner leaves entry, office, checkpoint and orphan receipt for restart diagnosis')
print('\n'.join(results));print(f'{len(results)} mode integration checks passed; all simulation')
