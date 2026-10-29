#!/usr/bin/env python3
"""Prepare/finalize an immutable-fixture PDF identity experiment; never compile or launch."""
import argparse
import datetime
import difflib
import hashlib
import json
from pathlib import Path
import shutil
import subprocess

ROOT = Path(__file__).resolve().parents[2]
EXPERIMENT_ID = "samebook-source-retention-v1"
SOURCE_COMMIT = "9604287d99e34cb4be2fa88690aef31084dbca6d"
DEFAULT_PARENT = ".build/perf-continuation-20261029-release/build-manifest.json"
DEFAULT_BUILD_ID = "perf-samebook-20261029"


def local(value):
    path = Path(value)
    path = (path if path.is_absolute() else ROOT / path).resolve()
    if path == ROOT or not path.is_relative_to(ROOT):
        raise ValueError("experiment paths must remain inside this workspace")
    return path


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def read(path):
    return json.loads(path.read_text())


def write(path, value):
    path.write_text(json.dumps(value, ensure_ascii=False, indent=2) + "\n")


def replace_once(text, before, after):
    if text.count(before) != 1:
        raise ValueError("experiment hook preimage must occur exactly once: " + before)
    return text.replace(before, after, 1)


STATE_FIELDS = '''["phase": "PHASE", "selectedPage": selectedUnit?.page ?? -1,
            "workspacePage": workspaceMemory.pdf?.page ?? -1,
            "workspaceX": workspaceMemory.pdf?.location?.x ?? -1,
            "workspaceY": workspaceMemory.pdf?.location?.y ?? -1,
            "route": route, "sourceURLPresent": sourceFileURL != nil]'''


def patch_appstore(text):
    before = '''        PerfTrace.event("book.select.begin")
        defer { PerfTrace.event("book.select.end") }'''
    after = before + '''
        PerfTrace.event("samebook.select.state", ''' + STATE_FIELDS.replace("PHASE", "before") + ''')
        defer { PerfTrace.event("samebook.select.state", ''' + STATE_FIELDS.replace("PHASE", "after") + ''') }'''
    text = replace_once(text, before, after)
    before = '''        let generation = navigationGeneration
        bookID = id; route = "reader"; sourceFileURL = nil;'''
    after = '''        let generation = navigationGeneration
        // Diagnostic hypothesis only. The immutable copied fixture never changes
        // bytes. This is deliberately NOT a product source-version check.
        let perfSameBookReader = bookID == id && route == "reader"
        let perfOwnPDF = sourceFileURL.map {
            $0.isFileURL && $0.pathExtension.lowercased() == "pdf"
                && $0.standardizedFileURL.resolvingSymlinksInPath().path.hasPrefix(libraryRootURL.standardizedFileURL.resolvingSymlinksInPath().path + "/")
        } ?? false
        let perfRetain = ProcessInfo.processInfo.environment["READINGBOOK_SAMEBOOK_VARIANT"] == "retain-source"
            && perfSameBookReader && perfOwnPDF
        let perfRetainedURL = perfRetain ? sourceFileURL : nil
        PerfTrace.event("samebook.retention-decision", ["variant": ProcessInfo.processInfo.environment["READINGBOOK_SAMEBOOK_VARIANT"] ?? "missing",
            "retained": perfRetain, "sameBookReader": perfSameBookReader, "ownPDF": perfOwnPDF])
        bookID = id; route = "reader"; sourceFileURL = perfRetainedURL;'''
    return replace_once(text, before, after)


def patch_pdf_reader(text):
    before = '''        if memory.isValid { memoryCallback?(memory) }'''
    after = '''        if memory.isValid {
            PerfTrace.event("samebook.pdf-memory-capture", [
                "viewCurrentPage": currentPageNumber ?? -1, "destinationPage": index + 1,
                "controllerPage": controller?.page ?? -1,
                "destinationX": Double(destination.point.x), "destinationY": Double(destination.point.y),
                "normalizedX": location.x, "normalizedY": location.y,
                "scale": Double(pdfView.scaleFactor), "documentGeneration": documentGeneration,
                "containerIdentity": String(describing: ObjectIdentifier(self)),
                "documentIdentity": String(describing: ObjectIdentifier(document))])
            memoryCallback?(memory)
        }'''
    return replace_once(text, before, after)


def source_patch(source, source_commit):
    changes = []
    for target in sorted((source / "Sources").rglob("*.swift")):
        relative = target.relative_to(source).as_posix()
        result = subprocess.run(["git", "show", source_commit + ":" + relative], cwd=ROOT,
                                text=True, capture_output=True)
        original = result.stdout if result.returncode == 0 else ""
        changes.extend(difflib.unified_diff(original.splitlines(True), target.read_text().splitlines(True),
                                          fromfile="a/" + relative, tofile="b/" + relative))
    return "".join(changes)


def validate_build_id(build_id):
    if not build_id.replace("-", "").replace("_", "").isalnum():
        raise ValueError("build-id must be alphanumeric with hyphens/underscores")


def prepare(parent_path, build_id):
    validate_build_id(build_id)
    parent_path = local(parent_path)
    parent = read(parent_path)
    if parent.get("sourceCommit") != SOURCE_COMMIT or not parent.get("buildSucceeded"):
        raise ValueError("the verified 9604 Release parent is required")
    parent_source, parent_root = local(parent["sourceRoot"]), local(parent["buildRoot"])
    archive = parent_root / "tracked-source.tar"
    parent_log_patch = ROOT / "logs" / parent_root.name / "instrumentation.patch"
    current_parent_patch = source_patch(parent_source, SOURCE_COMMIT)
    if (sha(archive) != parent["archiveSHA256"]
            or sha(parent_log_patch) != parent["instrumentationPatchSHA256"]
            or hashlib.sha256(current_parent_patch.encode()).hexdigest() != parent["instrumentationPatchSHA256"]):
        raise ValueError("parent source archive/instrumentation fingerprint changed")
    base, logs = ROOT / ".build" / build_id, ROOT / "logs" / build_id
    if base.exists() or logs.exists():
        raise ValueError("new experiment directory required; existing evidence is never overwritten")
    base.mkdir()
    logs.mkdir()
    source = base / "source"
    shutil.copytree(parent_source, source)
    shutil.copy2(archive, base / "tracked-source.tar")
    appstore = source / "Sources/ReadingBook/AppStore.swift"
    appstore.write_text(patch_appstore(appstore.read_text()))
    pdf = source / "Sources/ReadingBook/PDFReaderView.swift"
    pdf.write_text(patch_pdf_reader(pdf.read_text()))
    # prepare.py --resume refreshes PerfProbe/PerfTrace from the tools directory;
    # all experiment-specific changes are intentionally in the two archived files.
    definition = {
        "id": EXPERIMENT_ID, "createdAt": datetime.datetime.now(datetime.timezone.utc).isoformat(),
        "sourceCommit": SOURCE_COMMIT, "parentManifest": str(parent_path),
        "parentManifestSHA256": sha(parent_path), "parentInstrumentationPatchSHA256": parent["instrumentationPatchSHA256"],
        "sourceRoot": str(source), "buildRoot": str(base), "buildID": build_id,
        "variants": ["baseline", "retain-source"], "variantEnvironmentKey": "READINGBOOK_SAMEBOOK_VARIANT",
        "immutableFixtureRequired": True, "productSourcesModified": False, "compiled": False,
        "experimentSourceSHA256": {str(p.relative_to(source)): sha(p) for p in [appstore, pdf]},
        "limits": ["Only immutable copied PDF sources; this bypasses source invalidation and is not a product implementation.",
                   "Both variants run the complete selectBook reset/restore/source lookup path; only temporary source URL clearing changes.",
                   "The same diagnostic binary is used in both arms. No system recognition/selection/search feature is disabled.",
                   "The surrounding visible reader must already be mounted; library-route recreation is not addressed."]}
    definition_path = base / "samebook-experiment-definition.json"
    write(definition_path, definition)
    write(logs / "samebook-experiment-definition.json", definition)
    (logs / "instrumentation.patch").write_text(source_patch(source, SOURCE_COMMIT))
    write(base / "build-manifest.json", {"sourceCommit": SOURCE_COMMIT, "buildRoot": str(base), "sourceRoot": str(source),
          "buildSucceeded": False, "diagnosticOnly": True, "formalFPSBaselineExcluded": True,
          "sameBookExperiment": {"id": EXPERIMENT_ID, "definitionSHA256": sha(definition_path), "immutableFixtureRequired": True}})
    return {"status": "prepared-not-compiled", "buildRoot": str(base), "sourceCommit": SOURCE_COMMIT,
            "nextCompileArguments": ["python3", "scripts/mac-performance/prepare.py", "--resume", "--ref", SOURCE_COMMIT, "--build-id", build_id],
            "nextFinalizeArguments": ["python3", "scripts/mac-performance/prepare-samebook-experiment.py", "--finalize", "--build-id", build_id]}


def finalize(build_id):
    validate_build_id(build_id)
    base = ROOT / ".build" / build_id
    definition_path = base / "samebook-experiment-definition.json"
    definition, manifest = read(definition_path), read(base / "build-manifest.json")
    source, logs = local(manifest["sourceRoot"]), ROOT / "logs" / build_id
    if (definition.get("id") != EXPERIMENT_ID or definition.get("sourceCommit") != SOURCE_COMMIT
            or manifest.get("sourceCommit") != SOURCE_COMMIT or manifest.get("buildSucceeded") is not True
            or local(manifest["buildRoot"]) != base or source != base / "source"):
        raise ValueError("compiled experiment identity mismatch")
    for relative, expected in definition["experimentSourceSHA256"].items():
        if sha(source / relative) != expected:
            raise ValueError("prepared diagnostic source changed: " + relative)
    patch = source_patch(source, SOURCE_COMMIT)
    if (hashlib.sha256(patch.encode()).hexdigest() != manifest["instrumentationPatchSHA256"]
            or sha(logs / "instrumentation.patch") != manifest["instrumentationPatchSHA256"]
            or sha(local(manifest["app"]) / "Contents/MacOS/ReadingBook") != manifest["binarySHA256"]
            or sha(base / "tracked-source.tar") != manifest["archiveSHA256"]):
        raise ValueError("compiled source/patch/archive/binary fingerprint mismatch")
    manifest.update(diagnosticOnly=True, formalFPSBaselineExcluded=True,
                    formalFPSBaselineExclusionReasons=["same-book-source-retention-experiment"],
                    sameBookExperiment={"id": EXPERIMENT_ID, "definitionSHA256": sha(definition_path),
                        "immutableFixtureRequired": True, "sameBinaryBothArms": True,
                        "variantEnvironmentKey": "READINGBOOK_SAMEBOOK_VARIANT"})
    for path in [base / "build-manifest.json", logs / "build-manifest.json"]:
        write(path, manifest)
    return {"status": "finalized-diagnostic-only", "manifest": str(base / "build-manifest.json"),
            "binarySHA256": manifest["binarySHA256"], "variants": definition["variants"], "productSourcesModified": False}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    mode = parser.add_mutually_exclusive_group(required=True)
    mode.add_argument("--prepare-only", action="store_true")
    mode.add_argument("--finalize", action="store_true")
    parser.add_argument("--parent-manifest", default=DEFAULT_PARENT)
    parser.add_argument("--build-id", default=DEFAULT_BUILD_ID)
    args = parser.parse_args()
    print(json.dumps(prepare(args.parent_manifest, args.build_id) if args.prepare_only else finalize(args.build_id), indent=2))


if __name__ == "__main__":
    main()
