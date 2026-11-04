#!/usr/bin/env python3
"""Source-bound, network-denied native map-content integration."""
import argparse, datetime, hashlib, json, os, pathlib, plistlib, re, shutil, subprocess
R = pathlib.Path(__file__).resolve().parents[2]
p = argparse.ArgumentParser(); p.add_argument('--bin-dir', type=pathlib.Path, required=True); p.add_argument('--tag', required=True); p.add_argument('--source-file', type=pathlib.Path)
a = p.parse_args(); assert a.tag.replace('-', '').isalnum()
b = a.bin_dir.resolve(); out = R / 'logs/map-rendering-20261105' / a.tag
assert b.is_relative_to(R) and not out.exists()
for folder in [out, out/'tmp', out/'home']: folder.mkdir(parents=True, exist_ok=False)
work = R/'.build/map-trajectory-content-host'; work.mkdir(exist_ok=True)
host = pathlib.Path(__file__).with_name('MapTrajectoryContentHost.swift')
objects = [pathlib.Path(x) for x in (b/'ReadingBook.product/Objects.LinkFileList').read_text().splitlines() if not x.endswith('/ReadingBookLauncher.swift.o')]
swift, clang = R/'.build/shared-module-cache/swift', R/'.build/shared-module-cache/clang'
for folder in [swift, clang]: folder.mkdir(parents=True, exist_ok=True)
environment = dict(os.environ, TMPDIR=str(out/'tmp'), CFFIXED_USER_HOME=str(out/'home'))
source = (a.source_file or R/'Sources/ReadingBook/SpatialTimelineView.swift').resolve()
assert source.is_file() and source.is_relative_to(R)
combined = out/'CombinedTrajectory.swift'
combined.write_text('@testable import ReadingBook\n'+source.read_text()+'\n'+host.read_text())
binary = work/'MapTrajectoryContentHost'
command = ['swiftc', '-O', '-parse-as-library', '-enable-testing', '-module-name', 'MapContentReuseProbe', '-I', str(b/'Modules'), '-module-cache-path', str(swift), '-Xcc', '-fmodules-cache-path='+str(clang), str(combined), *map(str,objects), '-o', str(binary)]
with (out/'compile.log').open('x') as log: built = subprocess.run(command, cwd=R, env=environment, stdout=log, stderr=subprocess.STDOUT)
assert built.returncode == 0, 'Inspect '+str(out/'compile.log')
app = work/'ReadingBook Map Trajectory Content.app'; contents = app/'Contents'
if app.exists(): shutil.rmtree(app)
(contents/'MacOS').mkdir(parents=True); (contents/'Resources').mkdir()
shutil.copy2(binary, contents/'MacOS/MapTrajectoryContentHost')
bundle = contents/'Resources/ReadingBook_ReadingBook.bundle'; shutil.copytree(b/'ReadingBook_ReadingBook.bundle', bundle)
(contents/'Info.plist').write_bytes(plistlib.dumps(dict(CFBundleIdentifier='org.readingbook.map-trajectory-content-regression',CFBundleName='ReadingBook Map Trajectory Content',CFBundleExecutable='MapTrajectoryContentHost',CFBundlePackageType='APPL',NSHighResolutionCapable=True)))
subprocess.run(['codesign','--force','--sign','-','--timestamp=none',str(app)],check=True,capture_output=True)
sha=lambda path:hashlib.sha256(path.read_bytes()).hexdigest()
sources = {str(file.relative_to(R)): sha(file) for file in list((R/'Sources').rglob('*.swift'))+[host,source,combined,pathlib.Path(__file__).resolve()]}
(out/'build-manifest.json').write_text(json.dumps(dict(sourceSHA256=sources,binarySHA256=sha(contents/'MacOS/MapTrajectoryContentHost'),objectSHA256={str(f.relative_to(R)):sha(f) for f in objects}),indent=2)+'\n')
blocked = b/'ReadingBook_ReadingBook.bundle'
profile='(version 1) (allow default) (deny network-outbound) (deny file-read* (subpath "/Users/wu/Knowledge/ReadingBook")) (deny file-write* (subpath "/Users/wu/Knowledge/ReadingBook")) (deny file-read* (subpath '+json.dumps(str(blocked))+'))'
(out/'resource-sandbox.sb').write_text(profile+'\n')
started=datetime.datetime.now().strftime('%Y-%m-%d %H:%M:%S')
with (out/'runtime.log').open('x') as log:
    child=subprocess.Popen(['/usr/bin/sandbox-exec','-p',profile,str(contents/'MacOS/MapTrajectoryContentHost'),str(out)],cwd=R,env=environment,stdout=log,stderr=subprocess.STDOUT)
    (out/'pid.txt').write_text(str(child.pid)+'\n')
    try: code=child.wait(timeout=120)
    except subprocess.TimeoutExpired:
        subprocess.run(['sample',str(child.pid),'2','-file',str(out/'timeout.sample.txt')],capture_output=True,timeout=8)
        child.kill();code=child.wait()
with (out/'unified.log').open('x') as log: unified=subprocess.run(['/usr/bin/log','show','--style','compact','--start',started,'--predicate','processIdentifier == '+str(child.pid)],stdout=log,stderr=subprocess.STDOUT,timeout=30)
record=json.loads((out/'result.json').read_text()) if (out/'result.json').exists() else {}
runtime=(out/'runtime.log').read_text()+(out/'unified.log').read_text()
warnings={key:runtime.count(pattern) for key,pattern in [('layout300','300 iterations'),('publishingDuringViewUpdates','Publishing changes from within view updates'),('attributeGraphCycles','AttributeGraph: cycle detected')]}
warnings['invalidViewGeometry']=len(re.findall(r'invalid (?:frame|view) (?:dimension|geometry)',runtime,re.I))
expected = {phase+kind for phase in ['initial','largeThree','crossBelowTwo','smallThree','sameCountNewCoordinates','clear','crossAboveThree','largeTwo'] for kind in ['Markers','Trajectory','SameMap','PreservesCamera']}
checks=record.get('checks',{})
frozen=all(sha(R/name)==value for name,value in sources.items())
passed=code==0 and unified.returncode==0 and record.get('status')=='passed' and set(checks)==expected and all(v is True for v in checks.values()) and frozen and not any(warnings.values()) and record.get('realNetworkRequests')==0 and record.get('originalLibraryUsed') is False
report=dict(probe='map-trajectory-content',status='passed' if passed else 'failed',passed=passed,checkCount=len(checks),expectedCheckNames=sorted(expected),exitCode=code,unifiedLogReturnCode=unified.returncode,runtimeWarnings=warnings,sourceStillFrozen=frozen,sourceSHA256=sources,record=record,realNetworkRequests=0,buildResourceFallbackDenied=True,outboundNetworkDenied=True,originalLibraryReadAndWriteDenied=True,productionNativeMap=True)
(out/'report.json').write_text(json.dumps(report,indent=2)+'\n');print(json.dumps(report))
raise SystemExit(0 if passed else 1)
