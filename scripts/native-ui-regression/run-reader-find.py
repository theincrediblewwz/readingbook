#!/usr/bin/env python3
from pathlib import Path
import argparse,datetime,hashlib,json,os,plistlib,re,shutil,subprocess
r=Path(__file__).resolve().parents[2];b=r/'logs/find-panel-startup-20261105'
p=argparse.ArgumentParser();p.add_argument('--tag',required=True);p.add_argument('--mode',choices=['inline','layout'],default='inline');p.add_argument('--bin-dir',type=Path,required=True);a=p.parse_args();assert a.tag.replace('-','').isalnum()
b.mkdir(parents=True,exist_ok=True);out=b/a.tag;assert not out.exists();out.mkdir();(out/'home').mkdir();(out/'tmp').mkdir()
release=a.bin_dir.resolve();assert release.is_relative_to(r);work=r/'.build/reader-find-host';work.mkdir(exist_ok=True)
objects=[Path(x) for x in (release/'ReadingBook.product/Objects.LinkFileList').read_text().splitlines() if not x.endswith('/ReadingBookLauncher.swift.o')]
host=Path(__file__).with_name('ReaderFindHost.swift' if a.mode=='inline' else 'ReaderFindLayoutHost.swift');sha=lambda p:hashlib.sha256(p.read_bytes()).hexdigest()
sources={str(f.relative_to(r)):sha(f) for f in [*r.glob('Sources/**/*.swift'),host,Path(__file__)]}
modules=list((release/'Modules').glob('*')); inputs={str(f.relative_to(r)):sha(f) for f in objects+modules if f.is_file()}
commands=subprocess.check_output(['ps','-axo','comm='],text=True).splitlines()
assert not any(('swift-frontend' in x or 'swiftc' in x or 'swift-build' in x) for x in commands),'Finish compiler processes before linking a fixture'
env=dict(os.environ,TMPDIR=str(out/'tmp'),CFFIXED_USER_HOME=str(out/'home'))
binary=work/'ReaderFindHost';cmd=['swiftc','-O','-parse-as-library','-enable-testing','-module-name','ReaderFindProbe','-I',str(release/'Modules'),'-module-cache-path',str(r/'.build/shared-module-cache/swift'),'-Xcc','-fmodules-cache-path='+str(r/'.build/shared-module-cache/clang'),str(host),*map(str,objects),'-o',str(binary)]
(out/'command.json').write_text(json.dumps(cmd,indent=2)+'\n')
with (out/'compile.log').open('x') as f:built=subprocess.run(cmd,cwd=r,env=env,stdout=f,stderr=subprocess.STDOUT)
assert built.returncode==0,'See preserved '+str(out/'compile.log')
app=work/(a.tag+'.app');contents=app/'Contents';(contents/'MacOS').mkdir(parents=True);(contents/'Resources').mkdir();shutil.copy2(binary,contents/'MacOS/ReaderFindHost');shutil.copytree(release/'ReadingBook_ReadingBook.bundle',contents/'Resources/ReadingBook_ReadingBook.bundle')
(contents/'Info.plist').write_bytes(plistlib.dumps(dict(CFBundleIdentifier='org.readingbook.reader-inline-find',CFBundleName='ReadingBook Inline Find',CFBundleExecutable='ReaderFindHost',CFBundlePackageType='APPL',NSHighResolutionCapable=True)))
subprocess.run(['codesign','--force','--sign','-','--timestamp=none',str(app)],check=True,capture_output=True)
(out/'manifest.json').write_text(json.dumps(dict(sourceSHA256=sources,objectSHA256={str(f.relative_to(r)):inputs[str(f.relative_to(r))] for f in objects},allLinkedInputsSHA256=inputs,binarySHA256=sha(contents/'MacOS/ReaderFindHost')),indent=2)+'\n')
profile='(version 1) (allow default) (deny network-outbound) (deny file-read* (subpath "/Users/wu/Knowledge/ReadingBook")) (deny file-write* (subpath "/Users/wu/Knowledge/ReadingBook")) (deny file-read* (subpath '+json.dumps(str(release/'ReadingBook_ReadingBook.bundle'))+'))'
(out/'sandbox.sb').write_text(profile+'\n');started=datetime.datetime.now().strftime('%Y-%m-%d %H:%M:%S')
with (out/'runtime.log').open('x') as f:
    child=subprocess.Popen(['/usr/bin/sandbox-exec','-p',profile,str(contents/'MacOS/ReaderFindHost'),str(out)],cwd=r,env=env,stdout=f,stderr=subprocess.STDOUT)
    try:code=child.wait(timeout=100)
    except subprocess.TimeoutExpired:
        subprocess.run(['sample',str(child.pid),'2','-file',str(out/'timeout.sample.txt')],capture_output=True,timeout=8);child.kill();code=child.wait()
with (out/'unified.log').open('x') as f:logs=subprocess.run(['/usr/bin/log','show','--style','compact','--start',started,'--predicate','processIdentifier == '+str(child.pid)],stdout=f,stderr=subprocess.STDOUT,timeout=30)
record=json.loads((out/'result.json').read_text()) if (out/'result.json').exists() else {}
text=(out/'runtime.log').read_text()+(out/'unified.log').read_text();warnings={k:text.count(v) for k,v in [('layout300','300 iterations'),('publishingDuringViewUpdates','Publishing changes from within view updates'),('attributeGraphCycles','AttributeGraph: cycle detected'),('unsatisfiableConstraints','Unable to simultaneously satisfy constraints:')]};warnings['invalidViewGeometry']=len(re.findall(r'invalid (?:frame|view) (?:dimension|geometry)',text,re.I))
frozen=all(sha(r/n)==h for n,h in sources.items()) and all(sha(r/n)==h for n,h in inputs.items());passed=code==logs.returncode==0 and record.get('status')=='passed' and frozen and not any(warnings.values())
report=dict(status='passed' if passed else 'failed',probe='reader-inline-find' if a.mode=='inline' else 'reader-find-layout',checkCount=len(record.get('checks',{})),record=record,exitCode=code,unifiedLogReturnCode=logs.returncode,runtimeWarnings=warnings,sourceStillFrozen=frozen,sourceSHA256=sources,sourceManifest=str((out/'manifest.json').relative_to(r)),outboundNetworkDenied=True,originalLibraryReadAndWriteDenied=True,buildResourceFallbackDenied=True)
(out/'report.json').write_text(json.dumps(report,indent=2)+'\n');print(json.dumps(report,indent=2));print('failed checks',[k for k,v in record.get('checks',{}).items() if not v])
raise SystemExit(0 if passed else 1)
