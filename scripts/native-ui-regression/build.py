#!/usr/bin/env python3
"""Link the real Debug product into a native UI regression executable without XCTest."""
import argparse, hashlib, json, os, pathlib, subprocess
SOURCE=pathlib.Path(__file__).resolve().parent
ROOT=pathlib.Path(subprocess.check_output(['git','-C',str(SOURCE),'rev-parse','--show-toplevel'],text=True).strip())
WORK=ROOT/'.build/native-ui-harness'
p=argparse.ArgumentParser()
p.add_argument('--bin-dir',type=pathlib.Path,help='Reuse an already completed Debug ReadingBook build')
a=p.parse_args()
for name in ['tmp','cache','swiftpm-cache']:(WORK/name).mkdir(parents=True,exist_ok=True)
env=os.environ.copy();env.update(TMPDIR=str(WORK/'tmp'),CLANG_MODULE_CACHE_PATH=str(WORK/'cache'),SWIFTPM_MODULECACHE_OVERRIDE=str(WORK/'cache'))
if a.bin_dir:
 bindir=(ROOT/a.bin_dir).resolve() if not a.bin_dir.is_absolute() else a.bin_dir.resolve()
 assert bindir.is_relative_to(ROOT)
else:
 scratch=WORK/'product'
 args=['swift','build','--scratch-path',str(scratch),'--cache-path',str(WORK/'swiftpm-cache'),'--disable-sandbox']
 with (WORK/'product-build.log').open('w') as log:subprocess.run(args,cwd=ROOT,env=env,stdout=log,stderr=subprocess.STDOUT,check=True)
 bindir=pathlib.Path(subprocess.check_output(args+['--show-bin-path'],cwd=ROOT,env=env,text=True).strip())
linklist=bindir/'ReadingBook.product/Objects.LinkFileList'
allobjects=linklist.read_text().splitlines()
objects=[x for x in allobjects if not x.endswith('/ReadingBookLauncher.swift.o')]
assert len(objects)==len(allobjects)-1, 'Expected exactly the product launcher object to be excluded'
assert (bindir/'Modules/ReadingBook.swiftmodule').exists()
source=SOURCE/'NativeUIHarness.swift'
source_bytes=source.read_bytes()
(WORK/'compiled-harness-source.swift').write_bytes(source_bytes)
args=['swiftc','-parse-as-library','-enable-testing','-g','-I',str(bindir/'Modules'),'-module-name','NativeUIHarness',str(source)]+objects+['-o',str(WORK/'native-ui-harness')]
with (WORK/'compile.log').open('w') as log:subprocess.run(args,cwd=ROOT,env=env,stdout=log,stderr=subprocess.STDOUT,check=True)
metadata={'sourceSHA256':hashlib.sha256(source_bytes).hexdigest(),'binarySHA256':hashlib.sha256((WORK/'native-ui-harness').read_bytes()).hexdigest(),'productBinDir':str(bindir),'productObjects':[{'file':str(pathlib.Path(x).relative_to(ROOT)),'sha256':hashlib.sha256(pathlib.Path(x).read_bytes()).hexdigest()} for x in objects]}
(WORK/'build-manifest.json').write_text(json.dumps(metadata,indent=2)+'\n')
print(json.dumps({'binary':str(WORK/'native-ui-harness'),'objectCount':len(objects),'compilerLogBytes':(WORK/'compile.log').stat().st_size},indent=2))
