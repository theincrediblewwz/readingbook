#!/usr/bin/env python3
"""Run only the workspace-built native regression app; never control the installed app."""
import argparse, datetime, hashlib, json, os, pathlib, plistlib, shutil, subprocess, time, sys
ROOT=pathlib.Path(subprocess.check_output(['git','-C',str(pathlib.Path(__file__).resolve().parent),'rev-parse','--show-toplevel'],text=True).strip())
SOURCE=pathlib.Path(__file__).resolve().parent
HARNESS=ROOT/'.build/native-ui-harness'
p=argparse.ArgumentParser()
p.add_argument('--library-copy',type=pathlib.Path)
p.add_argument('--mode',choices=['panel','workspace','pdf','samebook','boundary','navigation','continuation','urgent-search-overlay'],default='workspace')
p.add_argument('--hold-seconds',type=int,default=0,help='Keep the isolated continuation fixture open for manual visual QA (0-300 seconds)')
p.add_argument('--cycles',type=int,default=24)
p.add_argument('--tag',default='run')
a=p.parse_args()
assert 1<=a.cycles<=1000
assert 0<=a.hold_seconds<=300 and (not a.hold_seconds or a.mode=='continuation')
assert a.tag.replace('-','').replace('_','').isalnum()
if a.library_copy:
 a.library_copy=a.library_copy.resolve()
 assert a.library_copy.is_relative_to(ROOT) and a.library_copy.is_dir(), 'Only workspace-local test library copies are allowed'
assert a.mode not in {'pdf','samebook','boundary','navigation','continuation','urgent-search-overlay'} or not a.library_copy, 'Fixture correctness modes generate their own nonprivate libraries'
stamp=datetime.datetime.now().strftime('%Y%m%d-%H%M%S')
out=ROOT/'logs'/f'native-ui-harness-{stamp}-{a.tag}'
out.mkdir(parents=True,exist_ok=False)
work=HARNESS/'runs'/f'{stamp}-{a.tag}'
work.mkdir(parents=True,exist_ok=False)
library=work/'library'
if a.library_copy:
 shutil.copytree(a.library_copy,library)
else:
 library.mkdir()
app=work/'Native UI Regression.app'
contents=app/'Contents'
(contents/'MacOS').mkdir(parents=True)
(contents/'Resources').mkdir()
binary=contents/'MacOS/ReadingBookNativeUIHarness'
shutil.copy2(HARNESS/'native-ui-harness',binary)
build=json.loads((HARNESS/'build-manifest.json').read_text())
assert hashlib.sha256((HARNESS/'native-ui-harness').read_bytes()).hexdigest()==build['binarySHA256'], 'Harness binary changed; rebuild before running'
canonical_source_sha=hashlib.sha256((SOURCE/'NativeUIHarness.swift').read_bytes()).hexdigest()
assert canonical_source_sha==build['sourceSHA256'], 'Harness source changed; rebuild before running'
shutil.copytree(pathlib.Path(build['productBinDir'])/'ReadingBook_ReadingBook.bundle',contents/'Resources/ReadingBook_ReadingBook.bundle')
domain='org.readingbook.native-ui-harness'
(contents/'Info.plist').write_bytes(plistlib.dumps({'CFBundleIdentifier':domain,'CFBundleExecutable':binary.name,'CFBundleName':'Native UI Regression','CFBundlePackageType':'APPL','NSHighResolutionCapable':True,'LSUIElement':False}))
subprocess.run(['codesign','--force','--sign','-','--timestamp=none',str(app)],check=True,stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
env=os.environ.copy()
env.update(HARNESS_WORKSPACE=str(ROOT),HARNESS_OUTPUT=str(out),HARNESS_LIBRARY=str(library),HARNESS_MODE=a.mode,HARNESS_CYCLES=str(a.cycles),HARNESS_HOLD_SECONDS=str(a.hold_seconds),HARNESS_SYNTHETIC='0' if a.library_copy else '1',CFFIXED_USER_HOME=str(work/'home'),TMPDIR=str(HARNESS/'tmp'))
(work/'home').mkdir()
metadata={'mode':a.mode,'cycles':a.cycles,'synthetic':not bool(a.library_copy),'harnessSourceSHA256':canonical_source_sha,'harnessBinarySHA256':hashlib.sha256(binary.read_bytes()).hexdigest(),'sourceHead':subprocess.check_output(['git','rev-parse','HEAD'],cwd=ROOT,text=True).strip(),'productDiffSHA256':hashlib.sha256(subprocess.check_output(['git','diff','--','Sources/ReadingBook'],cwd=ROOT)).hexdigest()}
(out/'manifest.json').write_text(json.dumps(metadata,indent=2)+'\n')
shutil.copy2(HARNESS/'build-manifest.json',out/'build-manifest.json')
shutil.copy2(HARNESS/'compiled-harness-source.swift',out/'compiled-harness-source.swift')
start=datetime.datetime.now().strftime('%Y-%m-%d %H:%M:%S')
with (out/'console.log').open('w') as f:
 child=subprocess.Popen([str(binary)],cwd=ROOT,env=env,stdout=f,stderr=subprocess.STDOUT)
 (out/'pid.txt').write_text(str(child.pid)+'\n')
 try:
  child.wait(timeout=max(120 if a.mode in {'samebook','urgent-search-overlay'} else 45,a.cycles*1.5+25)+a.hold_seconds)
 except subprocess.TimeoutExpired:
  try:
   subprocess.run(['/usr/bin/sample',str(child.pid),'5','10','-file',str(out/'timeout.sample.txt')],timeout=15,stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
  except (subprocess.TimeoutExpired,OSError) as error:
   (out/'sampler-error.txt').write_text(str(error)+'\n')
  finally:
   if child.poll() is None: child.kill()
   child.wait()
  (out/'timeout.json').write_text(json.dumps({'status':'timeout','pid':child.pid})+'\n')
 time.sleep(0.3)
 with (out/'unified.log').open('w') as log:
  log_result=subprocess.run(['/usr/bin/log','show','--style','compact','--start',start,'--predicate',f'processIdentifier == {child.pid}'],stdout=log,stderr=subprocess.STDOUT,timeout=30)
text=(out/'unified.log').read_text()
console_text=(out/'console.log').read_text()
warnings={'layout300':text.count('300 iterations'),'publishingDuringViewUpdates':text.count('Publishing changes from within view updates'),
          'attributeGraphCycles':max(text.count('AttributeGraph: cycle detected'),console_text.count('AttributeGraph: cycle detected'))}
(out/'warnings.json').write_text(json.dumps(warnings,indent=2)+'\n')
# Preserve the test app's standard OS state in the workspace, then remove its throwaway preferences domain.
cleanup=work/'os-state'; cleanup.mkdir()
subprocess.run(['defaults','export',domain,str(cleanup/'preferences.plist')],stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
subprocess.run(['defaults','delete',domain],stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
user_temp=pathlib.Path(subprocess.check_output(['getconf','DARWIN_USER_TEMP_DIR'],text=True).strip())
for item,name in [(pathlib.Path.home()/'Library/Preferences'/(domain+'.plist'),'preferences-residual.plist'),(pathlib.Path.home()/'Library/Saved Application State'/(domain+'.savedState'),'saved-state'),(user_temp/(domain+'.savedState'),'temp-saved-state')]:
 if item.exists(): shutil.move(str(item),str(cleanup/name))
summary={'output':str(out),'returncode':child.returncode,'warnings':warnings,'unifiedLogReturncode':log_result.returncode}
if (out/'result.json').exists(): summary['result']=json.loads((out/'result.json').read_text())
summary['overallStatus']='passed' if child.returncode==0 and log_result.returncode==0 and summary.get('result',{}).get('status')=='passed' and not any(warnings.values()) else 'failed'
(out/'summary.json').write_text(json.dumps(summary,indent=2)+'\n')
print(json.dumps(summary,indent=2))
sys.exit(0 if summary['overallStatus']=='passed' else 1)
