#!/usr/bin/env python3
"""Link the real completed Debug product into an offline AppStore probe."""
import argparse
import hashlib
import json
import os
import pathlib
import subprocess

ROOT = pathlib.Path(__file__).resolve().parents[2]
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--bin-dir', type=pathlib.Path, required=True,
                    help='Use an already completed Debug ReadingBook build; never builds the product')
args = parser.parse_args()
bindir = (ROOT / args.bin_dir).resolve()
if not bindir.is_relative_to(ROOT):
    raise ValueError('Product objects must remain inside this workspace')
work = ROOT / '.build/ai-concurrency-probe'
for name in ['tmp']:
    (work / name).mkdir(parents=True, exist_ok=True)
objects = (bindir / 'ReadingBook.product/Objects.LinkFileList').read_text().splitlines()
linked = [item for item in objects if not item.endswith('/ReadingBookLauncher.swift.o')]
assert len(linked) == len(objects) - 1, 'Exactly one product launcher must be excluded'
source = ROOT / 'scripts/native-ui-regression/AIConcurrencyProbe.swift'
binary = work / 'ai-concurrency-probe'
shared = ROOT / '.build/shared-module-cache'
swift_cache, clang_cache = shared / 'swift', shared / 'clang'
for cache in [swift_cache, clang_cache]:
    cache.mkdir(parents=True, exist_ok=True)
env = os.environ.copy()
env.update(TMPDIR=str(work / 'tmp'), CLANG_MODULE_CACHE_PATH=str(clang_cache),
           SWIFTPM_MODULECACHE_OVERRIDE=str(swift_cache), SWIFT_MODULE_CACHE_PATH=str(swift_cache))
command = ['swiftc', '-parse-as-library', '-enable-testing', '-g', '-I', str(bindir / 'Modules'),
           '-module-cache-path', str(swift_cache), '-Xcc', '-fmodules-cache-path=' + str(clang_cache), '-module-name', 'AIConcurrencyProbe',
           str(source), *linked, '-o', str(binary)]
with (work / 'compile.log').open('w') as log:
    subprocess.run(command, cwd=ROOT, env=env, stdout=log, stderr=subprocess.STDOUT, check=True)
manifest = {'sourceSHA256': hashlib.sha256(source.read_bytes()).hexdigest(),
            'binarySHA256': hashlib.sha256(binary.read_bytes()).hexdigest(),
            'productBinDir': str(bindir),
            'productObjects': [{'file': str(pathlib.Path(item).relative_to(ROOT)),
                                'sha256': hashlib.sha256(pathlib.Path(item).read_bytes()).hexdigest()}
                               for item in linked], 'realNetworkRequests': 0}
(work / 'build-manifest.json').write_text(json.dumps(manifest, indent=2) + '\n')
print(json.dumps({'binary': str(binary), 'objectCount': len(linked)}))
