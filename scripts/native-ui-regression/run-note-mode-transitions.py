#!/usr/bin/env python3
"""Render actual note hosts through a sequence of scale/direction/layout changes."""
from pathlib import Path
import argparse,datetime,hashlib,json,os,plistlib,re,shutil,subprocess,sys
R=Path(__file__).resolve().parents[2]
p=argparse.ArgumentParser();p.add_argument('--bin-dir',type=Path,required=True);p.add_argument('--tag',required=True)
p.add_argument('--library-template',type=Path);p.add_argument('--scroller-style',choices=['legacy','overlay'],default='legacy');a=p.parse_args()
assert a.tag.replace('-','').isalnum();b=a.bin_dir.resolve();assert b.is_relative_to(R)
base=R/('private-books' if a.library_template else 'logs')/'note-mode-transitions-20261103';out=base/a.tag
assert not out.exists();out.mkdir(parents=True);(out/'home').mkdir();(out/'tmp').mkdir()
if a.library_template:
    template=a.library_template.resolve();assert (template/'books').is_dir()
    (out/'library').mkdir();shutil.copytree(template/'books',out/'library/books')
work=R/'.build/note-mode-transitions-host';work.mkdir(exist_ok=True)
source=Path(__file__).with_name('NoteModeTransitionsHost.swift')
objects=[Path(x) for x in (b/'ReadingBook.product/Objects.LinkFileList').read_text().splitlines() if not x.endswith('/ReadingBookLauncher.swift.o')]
sha=lambda f:hashlib.sha256(f.read_bytes()).hexdigest()
env=dict(os.environ,TMPDIR=str(out/'tmp'),CFFIXED_USER_HOME=str(out/'home'),NOTE_USE_LIBRARY='1' if a.library_template else '0',NOTE_SCROLLER_STYLE=a.scroller_style)
binary=work/'NoteModeTransitionsHost';cmd=['swiftc','-parse-as-library','-enable-testing','-I',str(b/'Modules'),'-module-cache-path',str(R/'.build/shared-module-cache/swift'),'-Xcc','-fmodules-cache-path='+str(R/'.build/shared-module-cache/clang'),str(source),*map(str,objects),'-o',str(binary)]
with (out/'compile.log').open('x') as log:built=subprocess.run(cmd,cwd=R,env=env,stdout=log,stderr=subprocess.STDOUT)
assert built.returncode==0,'See '+str(out/'compile.log')
app=work/'ReadingBook Note Mode Transitions Test.app';c=app/'Contents';(c/'MacOS').mkdir(parents=True,exist_ok=True);(c/'Resources').mkdir(exist_ok=True)
shutil.copy2(binary,c/'MacOS/NoteModeTransitionsHost');bundle=c/'Resources/ReadingBook_ReadingBook.bundle'
if bundle.exists():shutil.rmtree(bundle)
shutil.copytree(b/'ReadingBook_ReadingBook.bundle',bundle)
(c/'Info.plist').write_bytes(plistlib.dumps(dict(CFBundleIdentifier='org.readingbook.note-mode-transitions-test',CFBundleExecutable='NoteModeTransitionsHost',CFBundleName='ReadingBook Note Mode Transitions Test',CFBundlePackageType='APPL',NSHighResolutionCapable=True)))
subprocess.run(['codesign','--force','--sign','-','--timestamp=none',str(app)],check=True,capture_output=True)
(out/'build-manifest.json').write_text(json.dumps(dict(hostSourceSHA256=sha(source),binarySHA256=sha(binary),objects={str(x.relative_to(R)):sha(x) for x in objects}),indent=2)+'\n')
start=datetime.datetime.now().strftime('%Y-%m-%d %H:%M:%S')
with (out/'runtime.log').open('x') as log:
    child=subprocess.Popen([str(c/'MacOS/NoteModeTransitionsHost'),str(out)],cwd=R,env=env,stdout=log,stderr=subprocess.STDOUT)
    try:status=child.wait(timeout=150)
    except subprocess.TimeoutExpired:
        subprocess.run(['sample',str(child.pid),'3','-file',str(out/'timeout.sample.txt')],capture_output=True,timeout=10);child.kill();status=child.wait()
unified=subprocess.run(['/usr/bin/log','show','--style','compact','--start',start,'--predicate','processIdentifier == '+str(child.pid)],capture_output=True,text=True,timeout=30)
text=unified.stdout+unified.stderr;(out/'unified.log').write_text(text)
warnings={k:text.count(v) for k,v in [('layout300','300 iterations'),('publishingDuringViewUpdates','Publishing changes from within view updates'),('attributeGraphCycles','AttributeGraph: cycle detected')]}
warnings['invalidViewGeometry']=len(re.findall(r'invalid (?:frame|view) (?:dimension|geometry)',text,re.I))
record=json.loads((out/'result.json').read_text()) if (out/'result.json').exists() else {}
passed=status==0 and unified.returncode==0 and not any(warnings.values()) and record.get('status')=='passed'
report=dict(probe='note-mode-transitions',status='passed' if passed else 'failed',passed=passed,exitCode=status,runtimeWarnings=warnings,unifiedLogReturncode=unified.returncode,record=record,realModelRequests=0,hostSourceSHA256=sha(source),scrollerStyle=a.scroller_style)
(out/'report.json').write_text(json.dumps(report,indent=2)+'\n')
print(json.dumps(report))
sys.exit(0 if passed else 1)
