#!/usr/bin/env python3
"""Execute actual product folder intents and canonical write/owner preservation."""
from pathlib import Path
import argparse,datetime,hashlib,json,os,re,subprocess,sys
R=Path(__file__).resolve().parents[2]
p=argparse.ArgumentParser(description=__doc__);p.add_argument('--bin-dir',type=Path,required=True);p.add_argument('--tag',required=True);a=p.parse_args()
assert a.tag.replace('-','').isalnum();b=a.bin_dir.resolve();assert b.is_relative_to(R)
out=R/'logs/folder-control-20261102'/a.tag;assert not out.exists();out.mkdir(parents=True);(out/'home').mkdir();(out/'tmp').mkdir()
W=R/'.build/folder-identity-probe';W.mkdir(exist_ok=True);source=Path(__file__).with_name('FolderIdentityProbe.swift');binary=W/'FolderIdentityProbe'
objects=(b/'ReadingBook.product/Objects.LinkFileList').read_text().splitlines();linked=[x for x in objects if not x.endswith('/ReadingBookLauncher.swift.o')];assert len(linked)==len(objects)-1
swift=R/'.build/shared-module-cache/swift';clang=R/'.build/shared-module-cache/clang';swift.mkdir(parents=True,exist_ok=True);clang.mkdir(parents=True,exist_ok=True)
env=dict(os.environ,TMPDIR=str(out/'tmp'),CFFIXED_USER_HOME=str(out/'home'))
cmd=['swiftc','-O','-parse-as-library','-enable-testing','-I',str(b/'Modules'),'-module-cache-path',str(swift),'-Xcc','-fmodules-cache-path='+str(clang),str(source),*linked,'-o',str(binary)]
with(out/'compile.log').open('x')as log:compile_status=subprocess.run(cmd,cwd=R,env=env,stdout=log,stderr=subprocess.STDOUT).returncode
assert compile_status==0,'Folder identity probe did not compile; see '+str(out/'compile.log')
sha=lambda f:hashlib.sha256(f.read_bytes()).hexdigest()
(out/'build-manifest.json').write_text(json.dumps(dict(sourceSHA256=sha(source),productFolderSourceSHA256=sha(R/'Sources/ReadingBook/ReaderFolderControls.swift'),binarySHA256=sha(binary),objects=[dict(path=x,sha256=sha(Path(x)))for x in linked]),indent=2)+'\n')
start=datetime.datetime.now().strftime('%Y-%m-%d %H:%M:%S')
with(out/'runtime.log').open('x')as log:
 proc=subprocess.Popen([str(binary),str(R),str(out/'execution')],cwd=R,env=env,stdout=log,stderr=subprocess.STDOUT)
 status=proc.wait(timeout=60)
logs=subprocess.run(['/usr/bin/log','show','--style','compact','--start',start,'--predicate','processIdentifier == '+str(proc.pid)],capture_output=True,text=True,timeout=30)
raw=logs.stdout+logs.stderr;(out/'unified.log').write_text(raw)
warnings=dict(layout300=raw.count('300 iterations'),publishingDuringViewUpdates=raw.count('Publishing changes from within view updates'),attributeGraphCycles=raw.count('AttributeGraph: cycle detected'),invalidViewGeometry=len(re.findall(r'Invalid view geometry: (?:width|height) is negative',raw)))
record=json.loads((out/'execution/result.json').read_text())if(out/'execution/result.json').exists()else{}
expected={'renameKeepsOriginalTarget','renameDoesNotFollowChangedSelection','deletedRenameTargetRejected','rejectedRenameLeavesProjectBytes','renameWrongKindRejected','newChildKeepsCapturedParent','newRootDoesNotFollowLaterSelection','deletedCreateParentRejected','wrongKindCreateParentRejected','repositoryRenamesCapturedIdentity','canonicalWriterRejectsRenameDeletedAfterPreparation','canonicalWriterRejectsParentDeletedAfterPreparation','lateCommandsDoNotCreateOrRetargetFolders','folderRemovalPromotesChildAndUnfilesOnly','originalDocumentMetadataUnchanged','originalNoteBodyUnchanged','originalChatsUnchanged','originalSourceBytesUnchanged','lateBookOwnerDoesNotWrite','lateSourceOwnerDoesNotWrite','lateLibraryOwnerDoesNotWrite'}
expected.update({'removalKeepsOriginalTarget','removalDoesNotFollowChangedSelection','deletedRemovalTargetRejected','wrongKindRemovalTargetRejected','canonicalWriterRejectsRemovalDeletedAfterPreparation'})
passed=status==0 and logs.returncode==0 and not any(warnings.values())and record.get('status')=='passed'and record.get('checkCount')==len(expected)and set(record.get('checks',{}))==expected and all(record['checks'].values())and record.get('realNetworkRequests')==0
report=dict(probe='folder-identity',status='passed'if passed else'failed',passed=passed,pid=proc.pid,exitCode=status,unifiedLogReturncode=logs.returncode,runtimeWarnings=warnings,sourceSHA256=sha(source),productFolderSourceSHA256=sha(R/'Sources/ReadingBook/ReaderFolderControls.swift'),record=record)
(out/'report.json').write_text(json.dumps(report,indent=2)+'\n');print(json.dumps(report));sys.exit(0 if passed else 1)
