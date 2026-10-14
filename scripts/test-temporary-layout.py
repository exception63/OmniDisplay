#!/usr/bin/env python3
"""Session lifecycle integration; synthetic identities, simulation only."""
import copy, json, pathlib, subprocess, tempfile, time, uuid
ROOT=pathlib.Path(__file__).resolve().parent.parent
HELPER=ROOT/'dist/OmniDisplay.app/Contents/Helpers/OmniRecovery'
def read(p):
    try:return json.loads(p.read_text())
    except (FileNotFoundError,json.JSONDecodeError):return {}
def wait(d,phases):
    end=time.monotonic()+8
    while time.monotonic()<end:
        r=read(d/'receipt.json')
        if r.get('phase') in phases:return r
        time.sleep(.02)
    raise AssertionError(read(d/'receipt.json'))
def write(d,r): (d/'request.json').write_text(json.dumps(r))
def start(d):
    assert read(d/'request.json')['simulation'] is True
    p=subprocess.Popen([str(HELPER),'--transaction',str(d)],stdout=subprocess.DEVNULL,stderr=subprocess.PIPE)
    wait(d,['ready']);(d/'execute').touch();return p
def finish(p):
    p.wait(timeout=8); err=p.stderr.read().decode();assert p.returncode==0,err
    assert not err,err

def setup(base,operation='disconnect'):
    d=base/str(uuid.uuid4());d.mkdir()
    screens=[dict(id=f'00000000-0000-4000-8000-{i+1:012d}',displayID=i+1,name=f'Example {i}',active=True,main=i==0,builtin=False,mirrored=False,vendor=610,model=1,serial=i,x=i*1920,y=0,width=1920,height=1080,pixelWidth=3840,pixelHeight=2160,refresh=60,rotation=0) for i in range(3)]
    snap=dict(version=1,date=0,boot='simulation',displays=screens)
    temp=copy.deepcopy(snap);temp['displays'].pop(1);temp['displays'][1]['x']=1920
    session=dict(original=snap,temporary=temp,target=screens[1]['id'])
    before=copy.deepcopy(snap)
    if operation=='connect':before['displays'][1]['active']=False;before['displays'][2]['x']=1920
    r=dict(version=1,nonce=d.name,operation=operation,before=before,office=snap,keep=screens[0]['id'],target=screens[1]['id'],confirmedPhysical=True,simulation=True,timeout=.6,preserveLayout=True,layoutSession=session)
    write(d,r);return d,r
results=[]
with tempfile.TemporaryDirectory(prefix='omni-temp-layout-') as tmp:
    base=pathlib.Path(tmp)
    for trigger in ['timeout','cancel']:
        d,r=setup(base);p=start(d);wait(d,['awaitingConfirmation'])
        state=read(d/'simulated-displays.json');assert [x['x'] for x in state if x['active']]==[0,1920]
        if trigger=='cancel':(d/'cancel').touch()
        wait(d,['restored']);finish(p)
        assert read(d/'simulated-displays.json')==r['layoutSession']['original']['displays']
        results.append(f'PASS {trigger} restores full original layout')
    d,r=setup(base);p=start(d);wait(d,['awaitingConfirmation']);(d/'confirm').touch();wait(d,['confirmed']);finish(p)
    assert [x['x'] for x in read(d/'simulated-displays.json') if x['active']]==[0,1920]
    d,r=setup(base,'connect');p=start(d);wait(d,['restored']);finish(p)
    assert read(d/'simulated-displays.json')==r['layoutSession']['original']['displays']
    results.append('PASS confirmed temporary layout then full reconnect')
    d,r=setup(base);p=start(d);wait(d,['awaitingConfirmation'])
    state=read(d/'simulated-displays.json');state[1]['y']=20
    (d/'simulated-displays.json').write_text(json.dumps(state))
    wait(d,['failed']);finish(p)
    final=read(d/'simulated-displays.json');assert final[1]['y']==20 and all(x['active'] for x in final)
    results.append('PASS concurrent move triggers enable-only recovery without overwriting peers')
    d,r=setup(base);r['layoutSession']['temporary']['displays'][1]['x']+=1;write(d,r)
    p=start(d);wait(d,['failed']);p.wait(timeout=8)
    assert p.returncode!=0 and not (d/'simulated-displays.json').exists()
    results.append('PASS tampered temporary plan rejected before simulation mutation')
print('\n'.join(results));print(f'{len(results)} temporary-layout checks passed; all simulation')
