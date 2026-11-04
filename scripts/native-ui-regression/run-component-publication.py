#!/usr/bin/env python3
"""Run actual mounted graph/composition publication and source-isolation checks."""
import argparse, datetime, hashlib, json, os, pathlib, plistlib, re, shutil, subprocess, sys

ROOT=pathlib.Path(__file__).resolve().parents[2]
SCRIPT=pathlib.Path(__file__).resolve().parent
p=argparse.ArgumentParser()
p.add_argument('--bin-dir',type=pathlib.Path,required=True)
p.add_argument('--tag',required=True)
p.add_argument('--count',type=int,choices=[16,1024],default=1024)
a=p.parse_args()
assert a.tag.replace('-','').isalnum()
bindir=a.bin_dir.resolve();assert bindir.is_relative_to(ROOT)
out=ROOT/'logs/component-publication-20261104'/a.tag
assert not out.exists(),'Preserve previous evidence and use a fresh tag'
for path in [out/'home',out/'tmp',out/'instrumented-source']:path.mkdir(parents=True,exist_ok=False)
work=ROOT/'.build/component-publication-host';work.mkdir(exist_ok=True)
sha=lambda path:hashlib.sha256(path.read_bytes()).hexdigest()
source_hashes={}
copies=[]
for name in ['SpatialGraphViews.swift','CompositionWorkspaceView.swift']:
    original=ROOT/'Sources/ReadingBook'/name
    source_hashes[str(original.relative_to(ROOT))]=sha(original)
    text='@testable import ReadingBook\n'+original.read_text()
    if name=='SpatialGraphViews.swift':
        needle='if key == next { return snapshot }';assert text.count(needle)==2
        text=text.replace(needle,needle+'\n        let probeStart=ProcessInfo.processInfo.systemUptime\n        defer { PublicationMetrics.graph(next.kind, elapsed:(ProcessInfo.processInfo.systemUptime-probeStart)*1000, items:snapshot.items, lines:snapshot.lines) }')
    else:
        edits=[
            ('    private func refresh(includeBaseline: Bool = true, retainingContent: Bool = false) {\n',
             '    private func refresh(includeBaseline: Bool = true, retainingContent: Bool = false) {\n        PublicationMetrics.event("composition.refresh")\n'),
            ('            let worker = Task.detached(priority: .userInitiated) {\n',
             '            let worker = Task.detached(priority: .userInitiated) {\n                PublicationMetrics.beginWorker()\n                defer { PublicationMetrics.endWorker() }\n                let probeStart=ProcessInfo.processInfo.systemUptime\n'),
            ('                let baseline = try retainedBaseline ?? CompositionRuntime.project(prepared, selections: selection)',
             '                PublicationMetrics.prepared(reused:retainedPrepared != nil, elapsed:(ProcessInfo.processInfo.systemUptime-probeStart)*1000)\n                let baseline = try retainedBaseline ?? CompositionRuntime.project(prepared, selections: selection)'),
            ('                preparedInput = result.prepared; preparedOwner = owner; displayedOwner = owner',
             '                PublicationMetrics.published(result.projections)\n                preparedInput = result.prepared; preparedOwner = owner; displayedOwner = owner')]
        for before,after in edits:assert text.count(before)==1;text=text.replace(before,after,1)
    copied=out/'instrumented-source'/name;copied.write_text(text);copies.append(copied)
host=SCRIPT/'ComponentPublicationHost.swift'
for file in [host,pathlib.Path(__file__),ROOT/'Sources/ReadingBook/AppStore.swift']:
    source_hashes[str(file.relative_to(ROOT))]=sha(file)
objects=[pathlib.Path(x) for x in (bindir/'ReadingBook.product/Objects.LinkFileList').read_text().splitlines() if not x.endswith('/ReadingBookLauncher.swift.o')]
shared=ROOT/'.build/shared-module-cache';swift_cache=shared/'swift';clang_cache=shared/'clang'
for folder in [swift_cache,clang_cache]:folder.mkdir(parents=True,exist_ok=True)
environment=dict(os.environ,TMPDIR=str(out/'tmp'),CFFIXED_USER_HOME=str(out/'home'),SWIFT_MODULE_CACHE_PATH=str(swift_cache),CLANG_MODULE_CACHE_PATH=str(clang_cache))
binary=work/'ComponentPublicationHost'
command=['swiftc','-O','-parse-as-library','-enable-testing','-module-name','ComponentPublicationProbe','-I',str(bindir/'Modules'),'-module-cache-path',str(swift_cache),'-Xcc','-fmodules-cache-path='+str(clang_cache),str(host),*map(str,copies),*map(str,objects),'-o',str(binary)]
with (out/'compile.log').open('x') as log:
    built=subprocess.run(command,cwd=ROOT,env=environment,stdout=log,stderr=subprocess.STDOUT)
assert built.returncode==0,'Inspect preserved compiler output'
app=work/'ReadingBook Component Publication.app';contents=app/'Contents'
if app.exists():shutil.rmtree(app)
(contents/'MacOS').mkdir(parents=True);(contents/'Resources').mkdir()
shutil.copy2(binary,contents/'MacOS/ComponentPublicationHost')
bundle=contents/'Resources/ReadingBook_ReadingBook.bundle'
shutil.copytree(bindir/'ReadingBook_ReadingBook.bundle',bundle)
(contents/'Info.plist').write_bytes(plistlib.dumps(dict(CFBundleIdentifier='org.readingbook.component-publication-regression',CFBundleName='ReadingBook Component Publication',CFBundleExecutable='ComponentPublicationHost',CFBundlePackageType='APPL',NSHighResolutionCapable=True)))
subprocess.run(['codesign','--force','--sign','-','--timestamp=none',str(app)],check=True,capture_output=True)
app_binary=contents/'MacOS/ComponentPublicationHost'
manifest=dict(sourceFilesSHA256=source_hashes,hostSourceSHA256=sha(host),binarySHA256=sha(app_binary),standaloneBinarySHA256=sha(binary),copiedSourcesSHA256={f.name:sha(f) for f in copies},productObjectsSHA256={str(f.relative_to(ROOT)):sha(f) for f in objects})
(out/'build-manifest.json').write_text(json.dumps(manifest,indent=2)+'\n')
blocked=bindir/'ReadingBook_ReadingBook.bundle'
profile='(version 1) (allow default) (deny network-outbound) (deny file-read* (subpath '+json.dumps(str(blocked))+'))'
(out/'resource-sandbox.sb').write_text(profile+'\n')
started=datetime.datetime.now().strftime('%Y-%m-%d %H:%M:%S')
with (out/'runtime.log').open('x') as log:
    child=subprocess.Popen(['/usr/bin/sandbox-exec','-p',profile,str(app_binary),str(out),str(a.count)],cwd=ROOT,env=environment,stdout=log,stderr=subprocess.STDOUT)
    (out/'pid.txt').write_text(str(child.pid)+'\n')
    try:exit_code=child.wait(timeout=180)
    except subprocess.TimeoutExpired:
        subprocess.run(['sample',str(child.pid),'3','-file',str(out/'timeout.sample.txt')],capture_output=True,timeout=8)
        child.kill();exit_code=child.wait()
with (out/'unified.log').open('x') as log:
    system_log=subprocess.run(['/usr/bin/log','show','--style','compact','--start',started,'--predicate','processIdentifier == '+str(child.pid)],stdout=log,stderr=subprocess.STDOUT,timeout=30)
record=json.loads((out/'result.json').read_text()) if (out/'result.json').exists() else {}
runtime=(out/'unified.log').read_text()+(out/'runtime.log').read_text()
warnings={key:runtime.count(pattern) for key,pattern in [('layout300','300 iterations'),('publishingDuringViewUpdates','Publishing changes from within view updates'),('attributeGraphCycles','AttributeGraph: cycle detected')]}
warnings['invalidViewGeometry']=len(re.findall(r'invalid (?:frame|view) (?:dimension|geometry)',runtime,re.I))
suffixes=['CurrentBookBytesUnchanged','CurrentEditRendered','EqualStampAcceptedEditRendered','ExactOutputRetained','Mounted','WindowVisible','StaleStampRejected','ForeignStampRejected','AbsentStampRejected','RejectedWritesKeepEpochsAndOutput','UnstampedCurrentEditRendered','UnstampedOtherPublicationKeepsEpochAndOutput','SelectOtherAndBackShowsUpdatedCurrentBook','SameIdentifiersAcrossRootsInvalidate']
expected={mode+suffix for mode in ['documents','relations','composition'] for suffix in suffixes}
checks=record.get('checks',{})
other_rows=[x for x in record.get('records',[]) if x.get('phase')=='other-book-8']
no_extra_preparation=len(other_rows)==3 and {x['mode'] for x in other_rows}=={'documents','relations','composition'} and all(x['metrics']['counts']=={} for x in other_rows)
source_still_frozen=all(sha(ROOT/name)==value for name,value in source_hashes.items())
passed=exit_code==0 and system_log.returncode==0 and record.get('status')=='passed' and record.get('count')==a.count and record.get('syntheticUnits')==1484 and set(checks)==expected and all(value is True for value in checks.values()) and not any(warnings.values()) and no_extra_preparation and source_still_frozen and record.get('realNetworkRequests')==0 and record.get('originalLibraryUsed') is False and record.get('libraryRootMatchesRequested') is True
foreground=[value for row in other_rows for value in row.get('foregroundSamples',[])]
report=dict(probe='component-publication',status='passed' if passed else 'failed',passed=passed,exitCode=exit_code,unifiedLogReturncode=system_log.returncode,runtimeWarnings=warnings,hostSourceSHA256=sha(host),sourceFilesSHA256=source_hashes,sourceStillFrozen=source_still_frozen,checkCount=len(checks),expectedCheckNames=sorted(expected),noOtherBookProjectionStarted=no_extra_preparation,all24MeasuredUpdatesInForeground=len(foreground)==24 and all(foreground),foregroundRequiredForFunctionalCI=False,buildResourceFallbackDenied=True,outboundNetworkDenied=True,actualAppResourceBundle=str(bundle),blockedBuildResourceBundle=str(blocked),sandboxProfileSHA256=sha(out/'resource-sandbox.sb'),record=record,realNetworkRequests=0)
(out/'report.json').write_text(json.dumps(report,indent=2)+'\n')
# Retain only this isolated test domain; never edit the installed app's preferences.
os_state=out/'os-state';os_state.mkdir()
domain='org.readingbook.component-publication-regression'
subprocess.run(['defaults','export',domain,str(os_state/'preferences.plist')],capture_output=True)
subprocess.run(['defaults','delete',domain],capture_output=True)
print(json.dumps(report));sys.exit(0 if passed else 1)
