#!/usr/bin/env python3
"""Build a separate scroll driver with only two synchronous boundary notices.

The original input driver and its binary are never changed. This diagnostic
variant is excluded from ordinary latency/FPS baselines, and starts no app.
"""
import argparse
import datetime
import difflib
import hashlib
import json
import os
from pathlib import Path
import subprocess
import time

ROOT = Path(__file__).resolve().parents[2]
SOURCE = ROOT / "scripts/mac-performance/ScrollDrive.m"
BEGIN_ANCHOR = b"    self.startTicks = mach_absolute_time();\n"
END_ANCHOR = b"    if (self.ticker) { dispatch_source_cancel(self.ticker); self.ticker = nil; }\n"
BEGIN_LINE = b'    [[NSNotificationCenter defaultCenter] postNotificationName:@"ReadingBookScrollDiagnosticsBegin" object:nil];\n'
END_LINE = b'    [[NSNotificationCenter defaultCenter] postNotificationName:@"ReadingBookScrollDiagnosticsEnd" object:nil];\n'


def local(value):
    path = Path(value)
    path = (path if path.is_absolute() else ROOT / path).resolve()
    if ROOT not in path.parents:
        raise ValueError("outputs must be strictly inside the workspace")
    return path


def sha(data):
    return hashlib.sha256(data).hexdigest()


def write(path, value):
    path.write_text(json.dumps(value, ensure_ascii=False, indent=2) + "\n")


def generate(original):
    for anchor in (BEGIN_ANCHOR, END_ANCHOR):
        if original.count(anchor) != 1:
            raise ValueError("expected exactly one unchanged boundary anchor: " + repr(anchor))
    if b"ReadingBookScrollDiagnostics" in original:
        raise ValueError("original driver already contains diagnostic notifications")
    generated = original.replace(BEGIN_ANCHOR, BEGIN_ANCHOR + BEGIN_LINE, 1)
    generated = generated.replace(END_ANCHOR, END_ANCHOR + END_LINE, 1)
    assert generated.count(BEGIN_LINE) == generated.count(END_LINE) == 1
    assert generated.replace(BEGIN_LINE, b"", 1).replace(END_LINE, b"", 1) == original
    old_lines, new_lines = original.decode("utf-8").splitlines(True), generated.decode("utf-8").splitlines(True)
    changes = [x for x in difflib.SequenceMatcher(None, old_lines, new_lines).get_opcodes() if x[0] != "equal"]
    assert len(changes) == 2 and all(kind == "insert" and end - start == 1 for kind, _, _, start, end in changes)
    assert sorted(new_lines[start] for _, _, _, start, _ in changes) == sorted([BEGIN_LINE.decode(), END_LINE.decode()])
    patch = "".join(difflib.unified_diff(old_lines, new_lines, fromfile="original/ScrollDrive.m", tofile="diagnostic/ScrollDriveDiagnostics.m"))
    return generated, patch.encode("utf-8"), changes


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output-root", default=".build/perf-optimization-20261029/driver")
    parser.add_argument("--log-root", default="logs/perf-optimization-20261029/driver")
    parser.add_argument("--prepare-only", action="store_true", help="write source/proof/flags but do not invoke clang")
    args = parser.parse_args()
    output, logs = local(args.output_root), local(args.log_root)
    for folder in (output, logs):
        if folder.exists() and any(folder.iterdir()):
            raise ValueError("preserve earlier artifacts; choose fresh output/log roots: " + str(folder))
    original = SOURCE.read_bytes()
    generated, patch, changes = generate(original)
    original_binary = ROOT / ".build/scroll-frame-capture/libReadingBookScrollDrive.dylib"
    original_binary_sha = sha(original_binary.read_bytes()) if original_binary.exists() else None
    output.mkdir(parents=True, exist_ok=True)
    logs.mkdir(parents=True, exist_ok=True)
    temporary = output / "tmp"
    temporary.mkdir()
    cache = ROOT / ".build/shared-module-cache/clang"
    cache.mkdir(parents=True, exist_ok=True)
    generated_path = output / "ScrollDriveDiagnostics.m"
    patch_path = output / "ScrollDriveDiagnostics.patch"
    library = output / "libReadingBookDiagnosticScrollDrive.dylib"
    generated_path.write_bytes(generated)
    patch_path.write_bytes(patch)
    (logs / patch_path.name).write_bytes(patch)
    command = ["xcrun", "clang", "-dynamiclib", "-fobjc-arc", "-O2", "-mmacosx-version-min=15.0",
               "-fmodules", "-fmodules-cache-path=" + str(cache), "-Wall", "-Wextra", "-Werror",
               str(generated_path), "-framework", "Foundation", "-framework", "AppKit", "-framework", "PDFKit",
               "-o", str(library)]
    env = os.environ.copy()
    env.update(TMPDIR=str(temporary), CLANG_MODULE_CACHE_PATH=str(cache))
    flags = {"argv": command, "environmentOverrides": {"TMPDIR": str(temporary), "CLANG_MODULE_CACHE_PATH": str(cache)}}
    write(logs / "flags.json", flags)
    manifest = {
        "status": "prepared-diagnostic-driver-only", "createdAt": datetime.datetime.now().astimezone().isoformat(),
        "workspace": str(ROOT), "originalSource": str(SOURCE), "originalSourceSHA256": sha(original),
        "generatedSource": str(generated_path), "generatedSourceSHA256": sha(generated),
        "patch": str(patch_path), "patchSHA256": sha(patch), "builderSHA256": sha(Path(__file__).read_bytes()),
        "library": str(library), "flags": flags, "originalBinary": str(original_binary),
        "originalBinarySHA256": original_binary_sha,
        "proof": {"onlyTwoOneLineInsertions": True, "opcodes": changes, "removingOnlyNotificationsRestoresOriginalBytes": True,
                  "beginPostsPerSuccessfulStart": 1, "endPostsPerExistingFinish": 1,
                  "names": ["ReadingBookScrollDiagnosticsBegin", "ReadingBookScrollDiagnosticsEnd"],
                  "object": None, "userInfo": None, "noNewPerFrameWork": True,
                  "deliveryThreadBySourceInspection": "synchronous on existing main-queue start/finish; no new Task/dispatch",
                  "beginLocation": "after original startTicks, before timer/input setup",
                  "endLocation": "after original end ticks and ticker cancellation, before final geometry/JSON"},
        "productSourceChanged": False, "originalDriverReplaced": False, "runtimeTested": False,
        "latencyBaselineExcluded": True, "formalFPSBaselineExcluded": True,
    }
    write(logs / "build-manifest.json", manifest)
    if not args.prepare_only:
        started = time.monotonic()
        with (logs / "build.log").open("w") as log:
            result = subprocess.run(command, cwd=ROOT, env=env, stdout=log, stderr=subprocess.STDOUT)
        manifest.update(compileSeconds=time.monotonic() - started, compileReturnCode=result.returncode)
        manifest["status"] = "compiled-diagnostic-driver-only" if result.returncode == 0 else "failed-driver-compilation"
        if result.returncode == 0:
            manifest["librarySHA256"] = sha(library.read_bytes())
            result = subprocess.run(["/usr/bin/file", str(library)], cwd=ROOT, capture_output=True, text=True, check=True)
            manifest["binaryDescription"] = result.stdout.strip()
    manifest["originalSourceUnchanged"] = SOURCE.read_bytes() == original
    manifest["originalBinaryUnchanged"] = (sha(original_binary.read_bytes()) == original_binary_sha) if original_binary_sha else None
    if not manifest["originalSourceUnchanged"] or manifest["originalBinaryUnchanged"] is False:
        manifest["status"] = "failed-original-driver-preservation"
    write(logs / "build-manifest.json", manifest)
    write(output / "build-manifest.json", manifest)
    print(json.dumps({k: manifest.get(k) for k in ["status", "compileSeconds", "library", "librarySHA256", "originalSourceUnchanged", "originalBinaryUnchanged"]}), flush=True)
    return 0 if manifest["status"] in ["prepared-diagnostic-driver-only", "compiled-diagnostic-driver-only"] else 1


if __name__ == "__main__":
    raise SystemExit(main())
