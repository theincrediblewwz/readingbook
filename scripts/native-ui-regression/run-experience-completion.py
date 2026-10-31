#!/usr/bin/env python3
"""Exercise native note geometry and concurrent summaries against real product objects."""
import argparse, datetime, json, os, pathlib, shutil, subprocess, sys
ROOT = pathlib.Path(__file__).resolve().parents[2]
p = argparse.ArgumentParser()
p.add_argument('--bin-dir', type=pathlib.Path, required=True)
p.add_argument('--tag', default='automatic')
a = p.parse_args()
assert a.tag.replace('-','').replace('_','').isalnum()
output = ROOT/'logs/ux-completion-20261031'/a.tag
output.mkdir(parents=True, exist_ok=True)
assert not (output/'result.json').exists(), 'Use a fresh tag; preserve earlier receipts'
home = output/'home'; home.mkdir(exist_ok=True)
env = {**os.environ,'UX_WORKSPACE_ROOT':str(ROOT),'UX_EXIT_AFTER_CHECKS':'1','CFFIXED_USER_HOME':str(home), 'TMPDIR':str(ROOT/'logs/ux-completion-20261031/tmp')}
subprocess.run([sys.executable,str(pathlib.Path(__file__).with_name('build-experience-completion.py')),'--bin-dir',str(a.bin_dir),'--run-tag',a.tag],cwd=ROOT,env=env,check=True)
shutil.copy2(ROOT/'.build/experience-completion-host/manifest.json',output/'build-manifest.json')
binary = ROOT/'.build/experience-completion-host/ReadingBook UX Test.app/Contents/MacOS/ExperienceCompletionHost'
started = datetime.datetime.now().strftime('%Y-%m-%d %H:%M:%S')
with (output/'process.log').open('w') as log:
    try:
        child = subprocess.Popen([str(binary),str(output)],cwd=ROOT,env=env,stdout=log,stderr=subprocess.STDOUT)
        child.wait(timeout=45)
    except subprocess.TimeoutExpired:
        try:
            subprocess.run(['/usr/bin/sample',str(child.pid),'3','10','-file',str(output/'timeout.sample.txt')],stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL,timeout=10)
        finally:
            child.kill(); child.wait()
        print('Experience completion probe timed out',file=sys.stderr);sys.exit(1)
with (output/'unified.log').open('w') as log:
    log_result = subprocess.run(['/usr/bin/log','show','--style','compact','--start',started,'--predicate',f'processIdentifier == {child.pid}'],stdout=log,stderr=subprocess.STDOUT,timeout=30)
runtime = (output/'unified.log').read_text() + (output/'process.log').read_text()
warnings = {name:runtime.count(pattern) for name,pattern in [('layout300','300 iterations'),('publishingDuringViewUpdates','Publishing changes from within view updates'),('attributeGraphCycles','AttributeGraph: cycle detected')]}
records = {}
for name in ['geometry.json','memory-concurrency.json']:
    path = output/name
    records[name] = json.loads(path.read_text()) if path.exists() else {'passed':False,'error':'missing receipt'}
passed = child.returncode == 0 and log_result.returncode == 0 and not any(warnings.values()) and all(x.get('passed') is True for x in records.values())
manifest = json.loads((output/'build-manifest.json').read_text())
report = {'probe':'experience-completion','status':'passed' if passed else 'failed','passed':passed,
          'exitCode':child.returncode,'unifiedLogReturncode':log_result.returncode,'runtimeWarnings':warnings,
          'realNetworkRequests':0,'hostSourceSHA256':manifest['sourceSHA256'],'records':records}
(output/'result.json').write_text(json.dumps(report,ensure_ascii=False,indent=2))
print(json.dumps(report,ensure_ascii=False));sys.exit(0 if passed else 1)
