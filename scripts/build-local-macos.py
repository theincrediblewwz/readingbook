#!/usr/bin/env python3
"""Build a native Mac candidate locally, without GitHub, a ZIP or installation."""
import argparse
import datetime
import hashlib
import json
import os
from pathlib import Path
import platform
import plistlib
import shutil
import subprocess
import tempfile
import time


ROOT = Path(__file__).resolve().parents[1]
OUTPUT = ROOT / 'dist/local-candidate'
APP = OUTPUT / 'ReadingBook.app'
RECEIPT = OUTPUT / 'verification.json'
LOGS = ROOT / 'logs/local-candidate'


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def manifest(directory):
    result = {}
    for path in sorted(directory.rglob('*')):
        if path.is_symlink():
            raise RuntimeError('Unexpected symbolic link: ' + str(path))
        if path.is_file():
            result[str(path.relative_to(directory))] = dict(bytes=path.stat().st_size, sha256=digest(path))
    return result


def source_manifest():
    paths = [ROOT / 'Package.swift', ROOT / 'packaging/Info.plist',
             ROOT / 'scripts/make-icon.swift', Path(__file__).resolve()]
    paths += [p for p in (ROOT / 'Sources').rglob('*') if p.is_file()]
    return {str(p.relative_to(ROOT)): digest(p) for p in sorted(paths)}


def running_candidate():
    processes = subprocess.check_output(['ps', '-axo', 'comm='], text=True)
    return any(line.strip() == str(APP / 'Contents/MacOS/ReadingBook') for line in processes.splitlines())


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--configuration', choices=['debug', 'release'], default='release')
    args = parser.parse_args()
    if platform.system() != 'Darwin':
        parser.error('This script requires macOS.')
    if OUTPUT.is_symlink() or APP.is_symlink() or RECEIPT.is_symlink():
        parser.error('Candidate paths must not be symbolic links.')
    # Only replace this script's exact previous output; do not delete arbitrary directories.
    if APP.exists() or RECEIPT.exists():
        old = json.loads(RECEIPT.read_text())
        if old.get('generator') != 'scripts/build-local-macos.py' or old.get('status') != 'passed':
            parser.error('The existing candidate is not a verified output of this script.')
        if manifest(APP) != old.get('appFiles'):
            parser.error('The existing candidate changed; preserve it before rebuilding.')
    if running_candidate():
        parser.error('Quit the candidate normally before rebuilding it.')
    OUTPUT.mkdir(parents=True, exist_ok=True)
    LOGS.mkdir(parents=True, exist_ok=True)
    cache = ROOT / '.build/shared-module-cache/swift'
    cache.mkdir(parents=True, exist_ok=True)
    temporary = ROOT / '.build/tmp'
    temporary.mkdir(parents=True, exist_ok=True)
    env = os.environ.copy()
    env['TMPDIR'] = str(temporary)
    started = time.monotonic()
    sources = source_manifest()
    head = subprocess.check_output(['git', 'rev-parse', 'HEAD'], cwd=ROOT, text=True).strip()
    dirty = subprocess.check_output(['git', 'status', '--porcelain'], cwd=ROOT, text=True).splitlines()
    command = ['swift', 'build', '--configuration', args.configuration, '--product', 'ReadingBook',
               '--scratch-path', str(ROOT / '.build/mac-release'),
               '--cache-path', str(ROOT / '.build/swiftpm-cache'), '-Xswiftc', '-enable-testing']
    build_seconds = None
    with (LOGS / 'build.log').open('w') as log:
        def run(cmd, capture=False):
            log.write('$ ' + ' '.join(map(str, cmd)) + '\n')
            log.flush()
            if capture:
                result = subprocess.check_output(cmd, cwd=ROOT, env=env, text=True)
                log.write(result)
                return result.strip()
            subprocess.run(cmd, cwd=ROOT, env=env, stdout=log, stderr=subprocess.STDOUT, check=True)

        run(command)
        build_seconds = time.monotonic() - started
        binaries = Path(run(command + ['--show-bin-path'], capture=True))
        resources = binaries / 'ReadingBook_ReadingBook.bundle'
        if not (resources / 'Markdown/index.html').is_file():
            raise RuntimeError('The offline Markdown resources are missing.')
        # The staging directory is always workspace-local and removed after success or failure.
        with tempfile.TemporaryDirectory(prefix='local-package-', dir=ROOT / '.build') as scratch:
            stage = Path(scratch)
            app = stage / 'ReadingBook.app'
            (app / 'Contents/MacOS').mkdir(parents=True)
            (app / 'Contents/Resources').mkdir()
            shutil.copy2(binaries / 'ReadingBook', app / 'Contents/MacOS/ReadingBook')
            shutil.copy2(ROOT / 'packaging/Info.plist', app / 'Contents/Info.plist')
            shutil.copytree(resources, app / 'Contents/Resources/ReadingBook_ReadingBook.bundle')
            run(['swift', '-module-cache-path', str(cache), 'scripts/make-icon.swift', str(stage / 'icon.iconset')])
            run(['iconutil', '-c', 'icns', str(stage / 'icon.iconset'), '-o', str(app / 'Contents/Resources/AppIcon.icns')])
            run(['codesign', '--force', '--sign', '-', '--timestamp=none', str(app)])
            run(['codesign', '--verify', '--strict', '--all-architectures', str(app)])
            run([str(app / 'Contents/MacOS/ReadingBook'), '--verify-resources'])
            architectures = run(['lipo', '-archs', str(app / 'Contents/MacOS/ReadingBook')], capture=True).split()
            expected = 'arm64' if platform.machine() == 'arm64' else 'x86_64'
            if architectures != [expected] or sources != source_manifest():
                raise RuntimeError('The native architecture or source files changed during the build.')
            info = plistlib.loads((app / 'Contents/Info.plist').read_bytes())
            result = dict(status='passed', generator='scripts/build-local-macos.py', channel='local-candidate',
                          version=info['CFBundleShortVersionString'], build=str(info['CFBundleVersion']),
                          sourceCommit=head, sourceFilesSHA256=sources, dirtyWorkingTree=dirty,
                          configuration=args.configuration, architectures=architectures, strictCodeSignature='passed',
                          offlineResources='passed', appFiles=manifest(app),
                          builtAt=datetime.datetime.now(datetime.timezone.utc).isoformat(),
                          buildSeconds=round(build_seconds, 3), totalSeconds=round(time.monotonic() - started, 3),
                          appPath=str(APP), buildLog=str(LOGS / 'build.log'),
                          testsRunByThisScript=False, installed=False, githubAccessed=False)
            if running_candidate():
                raise RuntimeError('The candidate opened during packaging; quit it normally before retrying.')
            old_app = stage / 'previous.app'
            if APP.exists():
                APP.rename(old_app)
            try:
                app.rename(APP)
                if manifest(APP) != result['appFiles']:
                    raise RuntimeError('Candidate file verification failed after replacement.')
                temporary_receipt = OUTPUT / 'verification.json.pending'
                temporary_receipt.write_text(json.dumps(result, ensure_ascii=False, indent=2) + '\n')
                temporary_receipt.replace(RECEIPT)
            except BaseException:
                if APP.exists():
                    APP.rename(stage / 'rejected.app')
                if old_app.exists():
                    old_app.rename(APP)
                raise
    print(json.dumps({key: result[key] for key in ('status', 'appPath', 'configuration', 'architectures',
                     'buildSeconds', 'totalSeconds', 'installed', 'githubAccessed')}, ensure_ascii=False))


if __name__ == '__main__':
    main()
