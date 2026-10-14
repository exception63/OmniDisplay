"""Audit persistence smoke tests; both requests are simulation=true, no GUI or CG writes."""
from pathlib import Path
import json,subprocess,time,uuid,tempfile
root=Path(__file__).resolve().parents[1]
temporary=tempfile.TemporaryDirectory(prefix='omni-audit-tests-')
base=Path(temporary.name)
helper=root/'dist/OmniDisplay.app/Contents/Helpers/OmniRecovery'
fixture=json.loads((root/'Tests/OmniCoreTests/Fixtures/disconnect-replay-before.json').read_text())
for blocked in [False,True]:
 r=dict(fixture);r['nonce']=str(uuid.uuid4());r['simulation']=True;r['timeout']=.5;r.pop('liveConsent',None)
 d=base/r['nonce'];d.mkdir();(d/'request.json').write_text(json.dumps(r))
 assert r['simulation'] is True and not r.get('liveConsent')
 if blocked:(d/'audit').write_text('Simulated audit storage failure; do not overwrite')
 p=subprocess.Popen([str(helper),'--transaction',str(d)],stdout=subprocess.DEVNULL,stderr=subprocess.PIPE)
 end=time.monotonic()+5
 while time.monotonic()<end:
  try:
   if json.loads((d/'receipt.json').read_text())['phase']=='ready':break
  except (FileNotFoundError,json.JSONDecodeError):pass
  time.sleep(.02)
 else:raise AssertionError('no ready')
 prefixes={f:f.read_bytes() for f in (d/'audit/apply').glob('*.jsonl')} if not blocked else {}
 (d/'execute').touch();_,error=p.communicate(timeout=5);assert p.returncode==0,error
 assert json.loads((d/'receipt.json').read_text())['phase']=='restored'
 assert json.loads((d/'simulated-displays.json').read_text())==r['before']['displays']
 if not blocked:
  assert prefixes and all(f.read_bytes().startswith(data) for f,data in prefixes.items())
  for phase in ['apply','confirmation','restore']:
   fs=list((d/'audit'/phase).glob('*.jsonl'));assert fs
   for f in fs:
    rows=[json.loads(l) for l in f.read_text().splitlines()]
    assert all(x['nonce']==r['nonce'] and x['phase']==phase for x in rows)
    assert [x['sequence'] for x in rows]==list(range(1,len(rows)+1))
 else:
  assert (d/'audit').read_text()=='Simulated audit storage failure; do not overwrite'
  assert b'Owner audit unavailable' in error
 (d/'test-result.json').write_text(json.dumps({'passed':True,'simulation':True,'auditStorageBlocked':blocked}))
 print('PASS', 'audit storage failure does not block simulated recovery' if blocked else 'append-only per-phase logs preserve prefixes and identity',d.name)

temporary.cleanup()
