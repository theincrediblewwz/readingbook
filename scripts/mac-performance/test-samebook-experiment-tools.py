#!/usr/bin/env python3
"""Offline contracts for the isolated same-book hypothesis; no app/build/AI."""
import importlib.util
import json
from pathlib import Path
import tempfile
import unittest

TOOLS = Path(__file__).resolve().parent
ROOT = TOOLS.parents[1]


def module(name, file):
    spec = importlib.util.spec_from_file_location(name, TOOLS / file)
    value = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(value)
    return value


PREP = module("samebook_prepare", "prepare-samebook-experiment.py")
RUN = module("samebook_run", "run.py")


class SameBookExperimentContracts(unittest.TestCase):
    def setUp(self):
        temporary_root = ROOT / ".build/samebook-tool-tests"
        temporary_root.mkdir(parents=True, exist_ok=True)
        self.temporary = tempfile.TemporaryDirectory(dir=temporary_root)
        self.base = Path(self.temporary.name)
        self.definition = self.base / "samebook-experiment-definition.json"
        self.value = {"id": RUN.SAMEBOOK_EXPERIMENT_ID, "sourceCommit": PREP.SOURCE_COMMIT}
        self.definition.write_text(json.dumps(self.value))
        self.manifest = {"sourceCommit": PREP.SOURCE_COMMIT, "buildRoot": str(self.base),
            "diagnosticOnly": True, "formalFPSBaselineExcluded": True,
            "sameBookExperiment": {"id": RUN.SAMEBOOK_EXPERIMENT_ID,
                "definitionSHA256": RUN.sha(self.definition), "immutableFixtureRequired": True}}

    def tearDown(self):
        self.temporary.cleanup()

    def test_ordinary_probe_unchanged(self):
        ordinary = {"buildRoot": str(self.base / "ordinary")}
        self.assertIsNone(RUN.samebook_experiment(ordinary, None))
        self.assertEqual(RUN.diagnostic_metadata(), {"profiled": False, "scrollDiagnostic": None,
            "latencyBaselineExcluded": False, "latencyBaselineExclusionReasons": []})

    def test_both_arms_are_diagnostics(self):
        for arm in ("baseline", "retain-source"):
            metadata = RUN.samebook_experiment(self.manifest, arm)
            self.assertEqual(metadata["variant"], arm)
            result = RUN.diagnostic_metadata(False, None, metadata)
            self.assertTrue(result["latencyBaselineExcluded"])
            self.assertEqual(result["sameBookExperiment"], metadata)
            self.assertIn("same-book-source-retention-experiment", result["latencyBaselineExclusionReasons"])

    def test_explicit_arm_is_required_for_experiment(self):
        for arm in (None, "", "disabled", "unexpected"):
            with self.assertRaises(ValueError):
                RUN.samebook_experiment(self.manifest, arm)

    def test_normal_manifest_cannot_accept_arm(self):
        with self.assertRaises(ValueError):
            RUN.samebook_experiment({"buildRoot": str(self.base / "ordinary")}, "baseline")

    def test_unfinalized_resume_manifest_is_rejected(self):
        # prepare.py --resume overwrites its manifest before the explicit finalize.
        # The definition sidecar prevents that intermediate app from being baseline.
        intermediate = {"buildRoot": str(self.base), "sourceCommit": PREP.SOURCE_COMMIT}
        for arm in (None, "baseline", "retain-source"):
            with self.assertRaises(ValueError):
                RUN.samebook_experiment(intermediate, arm)

    def test_both_exclusion_flags_are_required(self):
        for key in ("diagnosticOnly", "formalFPSBaselineExcluded"):
            changed = {**self.manifest, key: False}
            with self.assertRaises(ValueError):
                RUN.samebook_experiment(changed, "baseline")

    def test_definition_mutation_is_rejected(self):
        self.definition.write_text(self.definition.read_text() + "\n")
        with self.assertRaises(ValueError):
            RUN.samebook_experiment(self.manifest, "retain-source")

    def test_wrong_source_is_rejected_even_with_matching_file_digest(self):
        self.value["sourceCommit"] = "0" * 40
        self.definition.write_text(json.dumps(self.value))
        self.manifest["sameBookExperiment"]["definitionSHA256"] = RUN.sha(self.definition)
        with self.assertRaises(ValueError):
            RUN.samebook_experiment(self.manifest, "retain-source")

    def test_immutable_fixture_requirement_cannot_be_disabled(self):
        self.manifest["sameBookExperiment"]["immutableFixtureRequired"] = False
        with self.assertRaises(ValueError):
            RUN.samebook_experiment(self.manifest, "retain-source")

    def test_archived_patch_preserves_full_book_selection_flow(self):
        original = '''    func selectBook(_ id: String, preferredRoute: String? = nil) async {
        PerfTrace.event("book.select.begin")
        defer { PerfTrace.event("book.select.end") }
        guard !editorDirty else { return }
        flushWorkspaceMemory()
        navigationGeneration += 1
        let generation = navigationGeneration
        bookID = id; route = "reader"; sourceFileURL = nil; selectedObjectID = nil
        let url = await repository.sourceURL(for: project)
        await preparePDFSession(bookID: id, sourceURL: url)
        restoreDraft()
        await restoreWorkspaceNavigation(expectedBookID: id, generation: generation)
        workspaceMemoryRevision &+= 1
    }'''
        patched = PREP.patch_appstore(original)
        self.assertNotIn('sourceFileURL = nil; selectedObjectID = nil', patched)
        self.assertIn('sourceFileURL = perfRetainedURL; selectedObjectID = nil', patched)
        for required in ('guard !editorDirty', 'flushWorkspaceMemory()', 'navigationGeneration += 1',
                         'let url = await repository.sourceURL(for: project)',
                         'await preparePDFSession(bookID: id, sourceURL: url)', 'restoreDraft()',
                         'await restoreWorkspaceNavigation(expectedBookID: id, generation: generation)',
                         'workspaceMemoryRevision &+= 1'):
            self.assertIn(required, patched)
        for guard in ('bookID == id && route == "reader"', 'perfSameBookReader && perfOwnPDF',
                      '.resolvingSymlinksInPath().path.hasPrefix(libraryRootURL',
                      'environment["READINGBOOK_SAMEBOOK_VARIANT"] == "retain-source"'):
            self.assertIn(guard, patched)

    def test_memory_telemetry_keeps_callback_and_page_definitions(self):
        original = '''    private func captureWorkspaceMemory() {
        if memory.isValid { memoryCallback?(memory) }
    }'''
        patched = PREP.patch_pdf_reader(original)
        for field in ('"viewCurrentPage": currentPageNumber', '"destinationPage": index + 1',
                      '"controllerPage": controller?.page', '"normalizedX": location.x',
                      '"destinationY": Double(destination.point.y)', 'memoryCallback?(memory)'):
            self.assertIn(field, patched)

    def test_hook_drift_fails_closed(self):
        for patch in (PREP.patch_appstore, PREP.patch_pdf_reader):
            with self.assertRaises(ValueError):
                patch("changed preimage")
        with self.assertRaises(ValueError):
            PREP.replace_once("repeat repeat", "repeat", "after")

    def test_paths_and_ids_remain_workspace_local(self):
        with self.assertRaises(ValueError):
            PREP.local("/tmp/samebook-experiment")
        for value in ("../escape", "bad/name", "with space"):
            with self.assertRaises(ValueError):
                PREP.validate_build_id(value)

    def test_launch_environment_always_selects_or_disables_arm_explicitly(self):
        self.assertEqual(RUN.samebook_launch_environment(None), {RUN.SAMEBOOK_VARIANT_ENV: "disabled"})
        for arm in ("baseline", "retain-source"):
            metadata = RUN.samebook_experiment(self.manifest, arm)
            self.assertEqual(RUN.samebook_launch_environment(metadata), {RUN.SAMEBOOK_VARIANT_ENV: arm})

    def execution_rows(self, arm="retain-source", creates=1):
        rows=[{"event":"samebook.retention-decision","ticks":1,"variant":arm,"retained":False,"sameBookReader":False,"ownPDF":False},
              {"event":"samebook.retention-decision","ticks":2,"variant":arm,"retained":arm=="retain-source","sameBookReader":True,"ownPDF":True}]
        for index in range(creates):
            rows.extend([{"event":"pdf.document-create.begin","ticks":3+index*2},
                         {"event":"pdf.document-create.end","ticks":4+index*2}])
        rows.append({"event":"run.completed","ticks":20})
        return rows

    def test_runtime_arm_requires_observed_flag_and_true_guard(self):
        metadata=RUN.samebook_experiment(self.manifest,"retain-source")
        rows=self.execution_rows()
        self.assertEqual(RUN.validate_samebook_execution(rows,metadata,2)["status"],"qualified-explicit-runtime-arm")
        for field, value in (("variant","baseline"),("retained",False),("ownPDF",False)):
            changed=[dict(row) for row in rows]
            changed[1][field]=value
            self.assertEqual(RUN.validate_samebook_execution(changed,metadata,2)["status"],"ineligible-runtime-arm")

    def test_missing_decision_cannot_pass_as_valid_arm(self):
        metadata=RUN.samebook_experiment(self.manifest,"baseline")
        validation=RUN.validate_samebook_execution(self.execution_rows("baseline",2)[1:],metadata,2)
        self.assertEqual(validation["status"],"ineligible-runtime-arm")

    def test_negative_identity_hypothesis_is_reported_without_faking_benefit(self):
        metadata=RUN.samebook_experiment(self.manifest,"retain-source")
        validation=RUN.validate_samebook_execution(self.execution_rows(creates=2),metadata,2)
        self.assertEqual(validation["status"],"qualified-explicit-runtime-arm")
        self.assertFalse(validation["documentCreationMatchesHypothesis"])
        self.assertEqual(validation["documentCreateBeginCount"],2)

    def test_post_completion_activity_is_excluded_from_experiment(self):
        metadata=RUN.samebook_experiment(self.manifest,"retain-source")
        rows=self.execution_rows()+[{"event":"samebook.retention-decision","ticks":30,"variant":"baseline","retained":False}]
        self.assertEqual(RUN.validate_samebook_execution(rows,metadata,2)["status"],"qualified-explicit-runtime-arm")

    def book_fixture(self):
        library=self.base/'library';book=library/'books/book-1'
        (book/'source').mkdir(parents=True)
        (book/'source/book.pdf').write_bytes(b'original PDF bytes')
        (book/'Notes').mkdir()
        (book/'Notes/user.md').write_text('original user note')
        (book/'AI分析').mkdir()
        (book/'AI分析/generated.md').write_text('generated view')
        (book/'project.json').write_text(json.dumps({'documents':[{'relativePath':'Notes/user.md'}]}))
        self.write_readable_manifest(book)
        return library,book

    def write_readable_manifest(self,book,extra=None):
        records={'AI分析/generated.md':{'path':'AI分析/generated.md','generatedHash':RUN.sha(book/'AI分析/generated.md')}}
        if extra:records.update(extra)
        (book/'.readingbook-readable.json').write_text(json.dumps({'version':1,'files':records}))

    def test_canonical_source_project_user_and_unknown_changes_are_rejected(self):
        library,book=self.book_fixture()
        before=RUN.samebook_book_bytes(library)
        for name in ('source/book.pdf','project.json','Notes/user.md','manual.md'):
            path=book/name;original=path.read_bytes() if path.exists() else None
            path.write_bytes(b'changed bytes')
            validation=RUN.validate_samebook_book_bytes(before,RUN.samebook_book_bytes(library))
            self.assertFalse(validation['qualified'],name)
            self.assertIn('book-1/'+name,[row['path'] for row in validation['protectedChanges']])
            if original is None:path.unlink()
            else:path.write_bytes(original)

    def test_hash_proven_generated_view_refresh_is_classified_separately(self):
        library,book=self.book_fixture();before=RUN.samebook_book_bytes(library)
        (book/'AI分析/generated.md').write_text('new generated view')
        self.write_readable_manifest(book)
        validation=RUN.validate_samebook_book_bytes(before,RUN.samebook_book_bytes(library))
        self.assertTrue(validation['qualified'])
        self.assertEqual(len(validation['generatedReadableChanges']),2)
        self.assertEqual(validation['protectedChanges'],[])

    def test_user_edited_generated_file_must_not_be_overwritten(self):
        library,book=self.book_fixture()
        (book/'AI分析/generated.md').write_text('user modified this generated view')
        before=RUN.samebook_book_bytes(library)
        (book/'AI分析/generated.md').write_text('regenerated content overwriting user')
        self.write_readable_manifest(book)
        validation=RUN.validate_samebook_book_bytes(before,RUN.samebook_book_bytes(library))
        self.assertFalse(validation['qualified'])
        self.assertEqual(before['files']['book-1/AI分析/generated.md']['category'],'unclassified-protected')

    def test_generated_manifest_cannot_exempt_registered_user_document(self):
        library,book=self.book_fixture()
        self.write_readable_manifest(book,{'Notes/user.md':{'path':'Notes/user.md','generatedHash':RUN.sha(book/'Notes/user.md')}})
        before=RUN.samebook_book_bytes(library)
        self.assertEqual(before['files']['book-1/Notes/user.md']['category'],'user-document')
        (book/'Notes/user.md').write_text('changed user text')
        self.write_readable_manifest(book,{'Notes/user.md':{'path':'Notes/user.md','generatedHash':RUN.sha(book/'Notes/user.md')}})
        self.assertFalse(RUN.validate_samebook_book_bytes(before,RUN.samebook_book_bytes(library))['qualified'])

    def test_book_metadata_is_explicit_and_source_deletion_is_rejected(self):
        library,book=self.book_fixture();before=RUN.samebook_book_bytes(library)
        (library/'books/.DS_Store').write_bytes(b'Finder metadata')
        validation=RUN.validate_samebook_book_bytes(before,RUN.samebook_book_bytes(library))
        self.assertTrue(validation['qualified'])
        self.assertEqual(len(validation['filesystemMetadataChanges']),1)
        (book/'source/book.pdf').unlink()
        self.assertFalse(RUN.validate_samebook_book_bytes(before,RUN.samebook_book_bytes(library))['qualified'])


if __name__ == "__main__":
    unittest.main(verbosity=2)
