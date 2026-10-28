#!/usr/bin/env python3
"""Link Debug objects into a never-shown hosted note undo diagnostic.

Requires the parent's frozen shared module-cache path. Never builds the product,
orders a window front, activates an app, or synthesizes OS input.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[2]


def local(value):
    path = Path(value).resolve()
    if not path.is_relative_to(ROOT):
        raise ValueError("All inputs, cache paths and outputs must stay in the workspace")
    return path


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--build-dir", required=True)
    parser.add_argument("--module-cache", default=ROOT / ".build/shared-module-cache/swift", help="Parent-approved shared Swift cache")
    parser.add_argument("--clang-module-cache", default=ROOT / ".build/shared-module-cache/clang", help="Parent-approved shared Clang cache")
    parser.add_argument("--fixture", help="Optional explicit synthetic Markdown or checkpoint JSON; default is self-contained 8471B")
    parser.add_argument("--output", required=True)
    args = parser.parse_args()
    build, cache, clang_cache, output = map(local, [args.build_dir, args.module_cache, args.clang_module_cache, args.output])
    fixture = local(args.fixture) if args.fixture else None
    if not all(path.is_relative_to(ROOT / ".build") for path in [cache, clang_cache]):
        raise ValueError("Use the workspace shared .build module cache")
    sidecars = {kind: output.with_name(output.stem + suffix) for kind, suffix in
                [("build", "-build.json"), ("compile", "-build.log"), ("run", "-run.log"), ("source", "-source.swift")]}
    if output.exists() or any(path.exists() for path in sidecars.values()):
        raise FileExistsError("Choose a fresh output stem; probe evidence cannot be overwritten")
    linkfile = build / "ReadingBook.product/Objects.LinkFileList"
    originals = [local(path) for path in linkfile.read_text().splitlines()]
    objects = [path for path in originals if path.name != "ReadingBookLauncher.swift.o"]
    if len(objects) != len(originals) - 1 or not all(path.is_file() for path in objects):
        raise ValueError("Expected one excluded launcher and only complete existing product objects")
    if not (build / "Modules/ReadingBook.swiftmodule").is_file():
        raise ValueError("Completed testable Debug modules are required")
    work = ROOT / ".build/hosted-note-undo-probe"
    temporary = work / "tmp"
    for directory in [work, temporary, cache, clang_cache, output.parent]:
        directory.mkdir(parents=True, exist_ok=True)
    source = ROOT / "scripts/mac-note-editor/HostedNoteUndoProbe.swift"
    binary = work / "HostedNoteUndoProbe"
    command = ["xcrun", "swiftc", "-parse-as-library", "-enable-testing", "-g", "-D", "DEBUG", "-swift-version", "5",
        "-I", str(build / "Modules"), "-module-cache-path", str(cache), "-module-name", "HostedNoteUndoProbe",
        "-Xcc", f"-fmodules-cache-path={clang_cache}",
        str(source), *map(str, objects), "-o", str(binary)]
    environment = os.environ.copy()
    environment.update(TMPDIR=str(temporary), CLANG_MODULE_CACHE_PATH=str(clang_cache),
        SWIFTPM_MODULECACHE_OVERRIDE=str(cache), SWIFT_MODULE_CACHE_PATH=str(cache), MACOSX_DEPLOYMENT_TARGET="15.0")
    compiled = subprocess.run(command, cwd=ROOT, env=environment, capture_output=True, text=True)
    sidecars["compile"].write_text(compiled.stdout + compiled.stderr)
    sidecars["source"].write_bytes(source.read_bytes())
    identity = {"command": command, "sourceSHA256": sha(source), "explicitFixtureSHA256": sha(fixture) if fixture else None,
        "fixtureOrigin": "explicit-workspace-fixture" if fixture else "self-contained-synthetic-8471B",
        "objects": {str(path.relative_to(ROOT)): sha(path) for path in objects}, "compilerExitCode": compiled.returncode,
        "sharedModuleCache": str(cache), "sharedClangModuleCache": str(clang_cache), "productBuildStarted": False}
    if compiled.returncode == 0:
        identity["binarySHA256"] = sha(binary)
    sidecars["build"].write_text(json.dumps(identity, indent=2) + "\n")
    if compiled.returncode:
        print(compiled.stderr, file=sys.stderr)
        return compiled.returncode
    run_command = [str(binary), str(output)] + ([str(fixture)] if fixture else [])
    run = subprocess.run(run_command, cwd=ROOT, env=environment, capture_output=True, text=True)
    sidecars["run"].write_text(run.stdout + run.stderr)
    if run.stderr:
        print(run.stderr, file=sys.stderr)
    print(json.dumps({"output": str(output), "runtimeExitCode": run.returncode,
        "buildIdentity": str(sidecars["build"]), "windowNeverOrderedFront": True}, indent=2))
    return run.returncode


if __name__ == "__main__":
    sys.exit(main())
