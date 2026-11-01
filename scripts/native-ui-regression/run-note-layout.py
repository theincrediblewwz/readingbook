#!/usr/bin/env python3
"""Run the actual reader through zero-note -> editor -> saved-note layout."""
from pathlib import Path
import argparse,datetime,hashlib,json,os,plistlib,shutil,subprocess,sys
R=Path(__file__).resolve().parents[2]
p=argparse.ArgumentParser();p.add_argument('--bin-dir',type=Path,required=True);p.add_argument('--tag',required=True);p.add_argument('--scroller-style',choices=['legacy','overlay'],default='legacy');a=p.parse_args()
assert a.tag.replace('-','').isalnum();bindir=a.bin_dir.resolve();assert bindir.is_relative_to(R)
out=R/'logs/note-layout-covers-20261101'/a.tag;assert not out.exists();out.mkdir(parents=True);(out/'home').mkdir();(out/'tmp').mkdir()
work=R/'.build/note-layout-host';work.mkdir(exist_ok=True)
source=Path(__file__).with_name('NoteLayoutHost.swift')
objects=[Path(x) for x in (bindir/'ReadingBook.product/Objects.LinkFileList').read_text().splitlines() if not x.endswith('/ReadingBookLauncher.swift.o')]
sha=lambda f:hashlib.sha256(f.read_bytes()).hexdigest()
swift_cache=R/'.build/shared-module-cache/swift';clang_cache=R/'.build/shared-module-cache/clang'
swift_cache.mkdir(parents=True,exist_ok=True);clang_cache.mkdir(parents=True,exist_ok=True)
environment=dict(os.environ,NOTE_SCROLLER_STYLE=a.scroller_style,TMPDIR=str(out/'tmp'),CFFIXED_USER_HOME=str(out/'home'),CLANG_MODULE_CACHE_PATH=str(clang_cache),SWIFT_MODULECACHE_PATH=str(swift_cache))
binary=work/'NoteLayoutHost'
command=['swiftc','-parse-as-library','-enable-testing','-I',str(bindir/'Modules'),'-module-cache-path',str(swift_cache),'-Xcc','-fmodules-cache-path='+str(clang_cache),str(source),*[str(x) for x in objects],'-o',str(binary)]
with (out/'compile.log').open('x') as log:built=subprocess.run(command,cwd=R,env=environment,stdout=log,stderr=subprocess.STDOUT)
assert built.returncode==0,'Native note-layout host compilation failed'
app=work/'ReadingBook Note Layout Test.app';contents=app/'Contents';(contents/'MacOS').mkdir(parents=True,exist_ok=True);(contents/'Resources').mkdir(exist_ok=True)
shutil.copy2(binary,contents/'MacOS/NoteLayoutHost')
bundle=contents/'Resources/ReadingBook_ReadingBook.bundle'
if bundle.exists():shutil.rmtree(bundle)
shutil.copytree(bindir/'ReadingBook_ReadingBook.bundle',bundle)
(contents/'Info.plist').write_bytes(plistlib.dumps({'CFBundleIdentifier':'org.readingbook.note-layout-test','CFBundleExecutable':'NoteLayoutHost','CFBundleName':'ReadingBook Note Layout Test','CFBundlePackageType':'APPL','NSHighResolutionCapable':True}))
subprocess.run(['codesign','--force','--sign','-','--timestamp=none',str(app)],check=True,capture_output=True)
manifest={'hostSourceSHA256':sha(source),'binarySHA256':sha(binary),'objects':[{'path':str(x.relative_to(R)),'sha256':sha(x)}for x in objects]}
(out/'build-manifest.json').write_text(json.dumps(manifest,indent=2)+'\n')
start=datetime.datetime.now().strftime('%Y-%m-%d %H:%M:%S')
with (out/'runtime.log').open('x') as log:
    process=subprocess.Popen([str(contents/'MacOS/NoteLayoutHost'),str(out)],cwd=R,env=environment,stdout=log,stderr=subprocess.STDOUT)
    try:status=process.wait(timeout=60)
    except subprocess.TimeoutExpired:
        subprocess.run(['sample',str(process.pid),'3','-file',str(out/'timeout.sample.txt')],capture_output=True,timeout=10);process.kill();status=process.wait()
logs=subprocess.run(['/usr/bin/log','show','--style','compact','--start',start,'--predicate','processIdentifier == '+str(process.pid)],capture_output=True,text=True,timeout=30)
text=logs.stdout+logs.stderr;(out/'unified.log').write_text(text)
warning={'layout300':text.count('300 iterations'),'publishingDuringViewUpdates':text.count('Publishing changes from within view updates'),'attributeGraphCycles':text.count('AttributeGraph: cycle detected')}
record=json.loads((out/'result.json').read_text()) if (out/'result.json').exists() else {}
passed=status==0 and record.get('status')=='passed' and logs.returncode==0 and not any(warning.values())
report={'probe':'note-layout','status':'passed'if passed else'failed','passed':passed,'exitCode':status,'unifiedLogReturncode':logs.returncode,'runtimeWarnings':warning,'hostSourceSHA256':sha(source),'record':record,'realModelRequests':0}
(out/'report.json').write_text(json.dumps(report,indent=2)+'\n');print(json.dumps(report));sys.exit(0 if passed else 1)
