#!/usr/bin/env python3
"""Quarter-turn lifecycle tests. No hardware I/O; every request is simulation=true."""
import copy, json, pathlib, subprocess, tempfile, time, uuid
ROOT=pathlib.Path(__file__).resolve().parent.parent
HELPER=ROOT/'dist.noindex/OmniDisplay.app/Contents/Helpers/OmniRecovery'
def read(p):
    try:return json.loads(p.read_text())
    except (FileNotFoundError,json.JSONDecodeError):return {}
def wait(d, phases, timeout=10):
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
def done(p, success=True):
    p.wait(timeout=10);err=p.stderr.read().decode()
    assert (p.returncode==0)==success,err
    if success:assert not err,err
def setup(base, count=4, target=1, timeout=.5, remote=False):
    root=base/str(uuid.uuid4());d=root/'Transactions'/str(uuid.uuid4());d.mkdir(parents=True)
    screens=[dict(id=f'00000000-0000-4000-8000-{i+1:012d}',displayID=i+1,name=f'Example {i}',active=True,main=i==0,builtin=False,mirrored=False,vendor=610,model=1,serial=i,x=i*1920,y=0,width=1920,height=1080,pixelWidth=3840,pixelHeight=2160,refresh=60,rotation=0) for i in range(count)]
    baseline=dict(version=1,date=0,boot='simulation',displays=screens)
    entry=copy.deepcopy(baseline)
    if remote:
        single=copy.deepcopy(screens[target]);single.update(x=0,y=0,main=True);entry['displays']=[single]
    keep=next((x['id'] for x in entry['displays'] if x['id']!=screens[target]['id']),screens[target]['id'])
    r=dict(version=1,nonce=d.name,operation='rotate',before=entry,office=entry,keep=keep,target=screens[target]['id'],rotationDegrees=90,rotationBaseline=baseline,confirmedPhysical=True,simulation=True,timeout=timeout)
    (d/'request.json').write_text(json.dumps(r));(root/'demo-mode-office.json').write_text(json.dumps(baseline));return d,r,root
results=[]
with tempfile.TemporaryDirectory(prefix='omni-rotation-') as tmp:
    base=pathlib.Path(tmp)
    for count,target,remote in [(4,1,False),(4,0,False),(1,0,False),(4,2,True)]:
        d,r,root=setup(base,count,target,timeout=3,remote=remote);before=(root/'demo-mode-office.json').read_bytes();p=start(d);wait(d,['awaitingConfirmation'])
        assert (root/'demo-mode-office.json').read_bytes()==before
        (d/'confirm').touch();wait(d,['confirmed']);done(p)
        state=read(d/'simulated-displays.json');baseline=read(root/'demo-mode-office.json')
        assert next(x for x in state if x['id']==r['target'])['rotation']==90 and all(x['active'] for x in state)
        assert len(baseline['displays'])==count and next(x for x in baseline['displays'] if x['id']==r['target'])['rotation']==90
        assert read(d/'rotation-prior-baseline.json')==r['rotationBaseline']
        trace=read(d/'simulated-mode-work.json');assert len(trace)==1 and trace[0]['step']['action']=='arrange'
        results.append(f'PASS confirmed rotation count={count} target={target} remote={remote}, baseline changes only after confirmation')
    for cancel in [True,False]:
        d,r,root=setup(base,timeout=3 if cancel else .3);before=(root/'demo-mode-office.json').read_bytes();p=start(d);wait(d,['awaitingConfirmation'])
        if cancel:(d/'cancel').touch()
        wait(d,['restored']);done(p);assert read(d/'simulated-displays.json')==r['before']['displays'] and (root/'demo-mode-office.json').read_bytes()==before
        assert all(w['step']['action']=='arrange' for w in read(d/'simulated-mode-work.json'))
        results.append(f'PASS rotation {"cancel" if cancel else "timeout"} restores full entry with no enable/disable and no baseline change')
    for marker in ['simulation-fail-step-0','simulation-rotation-intermediate']:
        d,r,root=setup(base);(d/marker).touch();p=start(d);wait(d,['restored']);done(p)
        assert read(d/'simulated-displays.json')==r['before']['displays'] and read(root/'demo-mode-office.json')==r['rotationBaseline']
        results.append('PASS '+marker+' preserves or restores original orientation')
    for outcome in ['success','unstable','identity','layout','boot']:
        d,r,root=setup(base,timeout=3);(d/'simulation-postcommit-apply').touch()
        if outcome!='success':(d/('simulation-final-'+outcome)).touch()
        p=start(d)
        if outcome=='success':
            wait(d,['awaitingConfirmation']);assert read(root/'demo-mode-office.json')==r['rotationBaseline'];(d/'confirm').touch();wait(d,['confirmed'])
            assert len(read(d/'simulated-mode-work.json'))==1
        else:
            wait(d,['restored']);assert read(d/'simulated-displays.json')==r['before']['displays']
        done(p);results.append('PASS rotation committed-settle-deadline '+outcome+' uses bounded fresh verification and preserves confirmation gate')
    for interference in ['peer','hotplug','baseline']:
        d,r,root=setup(base,timeout=3);p=start(d);wait(d,['awaitingConfirmation']);state=read(d/'simulated-displays.json')
        if interference=='baseline':
            baseline=read(root/'demo-mode-office.json');baseline['date']=123;(root/'demo-mode-office.json').write_text(json.dumps(baseline));(d/'confirm').touch()
        else:
            if interference=='peer':state[0]['y']=13
            else:
                extra=copy.deepcopy(state[0]);extra.update(id=str(uuid.uuid4()),displayID=99,main=False,x=10000);state.append(extra)
            (d/'simulated-displays.json').write_text(json.dumps(state))
        wait(d,['failed']);done(p);assert read(d/'simulated-displays.json')==state
        if interference=='baseline':assert read(root/'demo-mode-office.json')==baseline
        results.append('PASS concurrent '+interference+' is not overwritten and reports incomplete state')
    d,r,root=setup(base,timeout=3);p=launch(d);wait(d,['ready']);p2=launch(d);wait(d,['failed']);done(p2,False);(d/'cancel').touch();done(p)
    assert not (d/'simulated-displays.json').exists();results.append('PASS duplicate helper refused and cancel before handshake writes nothing')
    d,r,root=setup(base,timeout=3);(d/'simulation-fail-rollback').touch();p=start(d);wait(d,['awaitingConfirmation']);(d/'cancel').touch();wait(d,['failed']);done(p)
    assert read(root/'demo-mode-office.json')==r['rotationBaseline'];results.append('PASS rollback failure remains failed without promoting baseline')
print('\n'.join(results));print(f'{len(results)} rotation integration checks passed; all simulation')
