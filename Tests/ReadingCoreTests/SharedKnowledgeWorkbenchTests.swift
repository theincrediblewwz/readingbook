import Foundation
import XCTest
@testable import ReadingCore

final class SharedKnowledgeWorkbenchTests: XCTestCase {
    private func book() -> BookProject {
        var value = BookProject(title: "共享资料回归", originalName: "book.txt", sourceHash: "fixture", units: [
            .init(id: "u1", order: 0, chapter: "第一章", page: 1, text: "刘备与关羽同行，二人相识。"),
            .init(id: "u2", order: 1, chapter: "第二章", page: 2, text: "刘备与关羽重逢，关羽说明来意。"),
            .init(id: "u3", order: 2, chapter: "后文", page: 3, text: "曹操来到此地。")])
        PluginEngine.seed(&value); value.views = []
        value.entities = [
            .init(id: "liu", typeID: "person", name: "刘备", summary: "旧的 AI 介绍", evidence: [.init(unitID: "u1", quote: value.units[0].text)]),
            .init(id: "guan", typeID: "person", name: "关羽", summary: "本页人物", evidence: [.init(unitID: "u1", quote: value.units[0].text)]),
            .init(id: "cao", typeID: "person", name: "曹操", evidence: [.init(unitID: "u3", quote: value.units[2].text)])]
        value.events = [.init(id: "meeting", name: "二人相识", summary: "最初相逢", participantIDs: ["liu", "guan"], evidence: [.init(unitID: "u1", quote: value.units[0].text)])]
        value.relations = [.init(id: "friends", fromID: "liu", toID: "guan", label: "相识", evidence: [.init(unitID: "u1", quote: value.units[0].text)])]
        return value
    }
    private func edit(_ project: BookProject) throws -> BookProject {
        var entity = project.entities[0]; entity.summary = "用户自己的理解 e\u{301} 🙂"
        return try KnowledgeUserEditsRuntime.applying(expected: .entity(project.entities[0]), replacement: .entity(entity), basis: .interpretation, to: project)
    }
    private func fixture() async throws -> (URL, LibraryRepository, BookProject) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ReadingBook-Shared-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        var value = book(); let data = Data(value.units.map(\.text).joined(separator: "\n").utf8)
        let source = root.appendingPathComponent("book.txt"); try data.write(to: source)
        value.sourceHash = try BookImporter.sha256(data)
        let repository = LibraryRepository(rootURL: root.appendingPathComponent("library"))
        return (root, repository, try await repository.create(value, sourceURL: source))
    }
    func testLegacyDecodeAddsNoDuplicateKnowledgeOrMandatoryMigration() throws {
        let original = book(), data = try JSONEncoder().encode(original)
        let result = try JSONDecoder().decode(BookProject.self, from: data)
        XCTAssertNil(result.knowledgeUserEdits); XCTAssertEqual(result.entities, original.entities)
        let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        XCTAssertNil(json["knowledgeUserEdits"])
    }
    func testManualCorrectionRecordsOnlyChangedFieldsAndSeparatesPersonalJudgment() throws {
        let original = book(), result = try edit(original)
        let record = try XCTUnwrap(result.knowledgeUserEdits?.records.first)
        XCTAssertEqual(record.fields, ["summary"]); XCTAssertEqual(record.basis, .interpretation)
        XCTAssertEqual(result.entities[0].evidence, original.entities[0].evidence)
        let json = String(decoding: try JSONEncoder().encode(result.knowledgeUserEdits), as: UTF8.self)
        XCTAssertFalse(json.contains("用户自己的理解")); XCTAssertFalse(json.contains("旧的 AI 介绍"))
        XCTAssertEqual(result.entities.count, original.entities.count)
    }
    func testProtectedSummarySurvivesWhileOtherFieldsAndEvidenceCanGrow() throws {
        let current = try edit(book()); var incoming = current
        incoming.entities[0].summary = "AI 企图覆盖"
        incoming.entities[0].aliases = ["玄德"]
        incoming.entities[0].evidence.append(.init(unitID: "u2", quote: current.units[1].text))
        let result = try KnowledgeUserEditsRuntime.preserving(incoming, from: current)
        XCTAssertEqual(result.entities[0].summary, current.entities[0].summary)
        XCTAssertEqual(result.entities[0].aliases, ["玄德"]); XCTAssertEqual(result.entities[0].evidence.count, 2)
    }
    func testExplicitlyClearedPropertiesAndCoordinatesCannotBeReintroduced() throws {
        var original = book(); original.entities[0].properties = ["description": "旧属性"]
        original.entities[0].latitude = 30; original.entities[0].longitude = 110
        var changed = original.entities[0]; changed.properties = [:]; changed.latitude = nil; changed.longitude = nil
        let edited = try KnowledgeUserEditsRuntime.applying(expected: .entity(original.entities[0]), replacement: .entity(changed), basis: .inference, to: original)
        var old = original; old.entities[0].aliases = ["新称谓"]
        let result = try KnowledgeUserEditsRuntime.preserving(old, from: edited)
        XCTAssertNil(result.entities[0].properties["description"]); XCTAssertNil(result.entities[0].latitude); XCTAssertNil(result.entities[0].longitude)
        XCTAssertEqual(result.entities[0].aliases, ["新称谓"])
    }
    func testUnchangedTextCanBeMarkedCheckedWithoutPretendingModelVerifiedIt() throws {
        let original = book()
        let result = try KnowledgeUserEditsRuntime.applying(expected: .entity(original.entities[0]), replacement: .entity(original.entities[0]), basis: .checkedSource, to: original)
        XCTAssertEqual(result.knowledgeUserEdits?.records.first?.basis, .checkedSource)
        XCTAssertEqual(result.knowledgeUserEdits?.records.first?.fields, [])
        let request = try TeacherBackgroundRequest.freeze(objectID: "liu", in: result, currentUnitID: "u1", avoidsSpoilers: true)
        XCTAssertFalse(request.knownFacts.contains("读者修正"))
        XCTAssertEqual(request.contextFingerprint, try TeacherBackgroundRequest.freeze(objectID: "liu", in: original, currentUnitID: "u1", avoidsSpoilers: true).contextFingerprint)
        let reuse = try XCTUnwrap(SavedKnowledgeReuse(project: result, currentUnitIDs: ["u2"]))
        XCTAssertNil(reuse.record(id: "liu")?["readerCorrection"])
        var noProof = original; noProof.entities[0].evidence = []
        XCTAssertThrowsError(try KnowledgeUserEditsRuntime.applying(expected: .entity(noProof.entities[0]), replacement: .entity(noProof.entities[0]), basis: .checkedSource, to: noProof))
    }
    func testEditsCannotRewriteEvidenceOrRecreateRemovedObjects() throws {
        let original = book(); var replacement = original.entities[0]; replacement.evidence = []
        XCTAssertThrowsError(try KnowledgeUserEditsRuntime.applying(expected: .entity(original.entities[0]), replacement: .entity(replacement), basis: .interpretation, to: original))
        let edited = try edit(original); var removed = edited; removed.entities.removeFirst()
        XCTAssertEqual(try KnowledgeUserEditsRuntime.preserving(removed, from: edited).entities.count, 2)
        XCTAssertThrowsError(try KnowledgeUserEditsRuntime.applying(expected: .entity(original.entities[0]), replacement: .entity(original.entities[0]), basis: .interpretation, to: removed))
    }
    func testEventAndRelationCorrectionsRetainSharedIDsAndOriginalEvidence() throws {
        let original = book()
        var current = original, event = current.events[0], relation = current.relations[0]
        event.name = "初次相识"; event.summary = "我的事件解释"
        current = try KnowledgeUserEditsRuntime.applying(expected: .event(current.events[0]), replacement: .event(event), basis: .inference, to: current)
        relation.label = "初识的朋友"
        current = try KnowledgeUserEditsRuntime.applying(expected: .relation(current.relations[0]), replacement: .relation(relation), basis: .interpretation, to: current)
        let result = try KnowledgeUserEditsRuntime.preserving(original, from: current)
        XCTAssertEqual(result.events[0], event); XCTAssertEqual(result.relations[0], relation)
        XCTAssertEqual(result.relations[0].fromID, "liu"); XCTAssertEqual(result.relations[0].toID, "guan")
        XCTAssertEqual(result.knowledgeUserEdits?.records.count, 2)
    }
    func testLateAIRebaseKeepsNewEvidenceAndConcurrentUserCorrection() throws {
        let base = book(), latest = try edit(base); var ai = base
        ai.entities[0].summary = "旧介绍\n\nAI 新内容"
        ai.entities[0].evidence.append(.init(unitID: "u2", quote: base.units[1].text))
        ai.entities[1].aliases.append("云长")
        let result = try AIProjectMerge.merge(base: base, result: ai, latest: latest)
        XCTAssertEqual(result.entities[0].summary, latest.entities[0].summary)
        XCTAssertEqual(result.entities[0].evidence.count, 2); XCTAssertEqual(result.entities[1].aliases, ["云长"])
        ai.knowledgeUserEdits = latest.knowledgeUserEdits
        XCTAssertThrowsError(try AIProjectMerge.merge(base: base, result: ai, latest: latest))
    }
    func testControlledAppendCannotOverwriteCorrectionsAndStillAddsEvidence() throws {
        var current = try edit(book()), relation = current.relations[0]
        relation.label = "我的关系判断"
        current = try KnowledgeUserEditsRuntime.applying(expected: .relation(current.relations[0]), replacement: .relation(relation), basis: .inference, to: current)
        var incoming = current.entities[0]; incoming.summary = "不应覆盖"
        incoming.evidence = [.init(unitID: "u2", quote: current.units[1].text)]
        var oldRelation = current.relations[0]; oldRelation.label = "相识"; oldRelation.evidence = incoming.evidence
        var identity = ControlledIdentityMap(operationID: "supplement", project: current)
        try ControlledKnowledgeRuntime.apply(.init(entities: [incoming], relations: [oldRelation]), to: &current, allowedUnitIDs: ["u2"], requiresReceipts: false, identity: &identity)
        XCTAssertEqual(current.entities[0].summary, "用户自己的理解 e\u{301} 🙂")
        XCTAssertEqual(current.entities[0].evidence.count, 2); XCTAssertEqual(current.relations[0].label, "我的关系判断")
        XCTAssertEqual(current.relations[0].evidence.count, 2)
    }
    func testRenamedObjectShowsAsUserLabelOnlyInsideItsSourceBoundary() throws {
        var original = book(), renamed = original.entities[0]; renamed.name = "玄德先生"; renamed.summary = "我的刘备介绍"
        original = try KnowledgeUserEditsRuntime.applying(expected: .entity(original.entities[0]), replacement: .entity(renamed), basis: .interpretation, to: original)
        let early = ReadingSpoilerProjection.entity(renamed, in: original, allowedUnitIDs: ["u1"])
        XCTAssertEqual(early?.name, "玄德先生"); XCTAssertEqual(early?.summary, "我的刘备介绍")
        XCTAssertNil(ReadingSpoilerProjection.entity(renamed, in: original, allowedUnitIDs: ["u3"]))
        var future = original; future.entities[0].evidence.append(.init(unitID: "u3", quote: future.units[2].text))
        XCTAssertNotEqual(ReadingSpoilerProjection.entity(future.entities[0], in: future, allowedUnitIDs: ["u1"])?.name, "玄德先生")
    }
    func testAtomicEditorKeepsConcurrentNotesAndRejectsStaleObjectInput() async throws {
        let (root, repository, original) = try await fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let note = DocumentRecord(id: "note", title: "原笔记", linkedIDs: ["liu"], evidence: original.entities[0].evidence)
        _ = try await repository.saveDocument(project: original, document: note, markdown: "原笔记 e\u{301}🙂")
        var changed = original.entities[0]; changed.summary = "我修正的内容"
        let saved = try await repository.saveKnowledgeEdit(bookID: original.id, sourceHash: original.sourceHash, expected: .entity(original.entities[0]), replacement: .entity(changed), basis: .interpretation)
        XCTAssertEqual(saved.documents.map(\.id), ["note"])
        let body = try await repository.readDocument(bookID: original.id, document: note); XCTAssertEqual(body, "原笔记 e\u{301}🙂")
        do { _ = try await repository.saveKnowledgeEdit(bookID: original.id, sourceHash: original.sourceHash, expected: .entity(original.entities[0]), replacement: .entity(changed), basis: .inference); XCTFail("stale must fail") } catch {}
        var stale = original; stale.documents = saved.documents
        let generic = try await repository.save(stale)
        XCTAssertEqual(generic.entities[0].summary, changed.summary); XCTAssertEqual(generic.knowledgeUserEdits, saved.knowledgeUserEdits)
    }
    func testWorkbenchTemplateIsClosedValidatedAndStoresOnlyQueries() throws {
        let request = try ReadingComponentRequest.decode(Data(#"{"componentID":"reading.composition","templateID":"reading-workbench"}"#.utf8))
        let definition = try XCTUnwrap(request.resolvedComposition)
        try CompositionRuntime.validate(definition, in: book())
        XCTAssertEqual(Set(definition.parts.map(\.primitive)), [.objectList, .relations, .objectDetail, .markdown])
        for raw in [#"{"componentID":"relations","templateID":"reading-workbench"}"#, #"{"componentID":"reading.composition","templateID":"unknown"}"#, #"{"componentID":"reading.composition","templateID":"reading-workbench","viewID":"x"}"#, #"{"componentID":"reading.composition","templateID":"reading-workbench","code":"run"}"#] { XCTAssertThrowsError(try ReadingComponentRequest.decode(Data(raw.utf8))) }
        let data = String(decoding: try JSONEncoder().encode(definition), as: UTF8.self)
        XCTAssertFalse(data.contains("刘备")); XCTAssertFalse(data.contains("旧的 AI 介绍"))
    }
    func testWorkbenchSelectionLinksRelationsEventsNotesAndUsesSameCorrection() throws {
        var current = try edit(book())
        current.documents = [.init(id: "note", title: "刘备笔记", linkedIDs: ["liu"], evidence: current.entities[0].evidence), .init(id: "other", title: "他人笔记", linkedIDs: ["guan"], evidence: current.entities[1].evidence)]
        let snapshot = try ReadingQuerySnapshot.freeze(scope: .readSoFar, in: current, context: .init(unitID: "u2", page: 2))
        let prepared = try CompositionRuntime.prepare(ReadingWorkbench.definition(), in: current, sourceSnapshot: snapshot)
        let selected = try CompositionRuntime.project(prepared, selections: ["main": ["liu"]])
        XCTAssertEqual(selected["details"]?.items.map(\.id), ["liu"])
        XCTAssertEqual(selected["details"]?.items.first?.summary, current.entities[0].summary)
        XCTAssertEqual(selected["events"]?.items.map(\.id), ["meeting"])
        XCTAssertEqual(selected["notes"]?.items.map(\.id), ["note"])
        XCTAssertEqual(selected["relations"]?.edges.map(\.id), ["friends"])
        XCTAssertFalse(selected["objects"]!.items.contains { $0.id == "cao" })
        XCTAssertEqual(current.documents.count, 2); XCTAssertEqual(current.entities.count, 3)
    }
    func testWorkbenchReusesSavedDefinitionAcrossTitleAndKeepsOriginalMarkdown() async throws {
        let (root, repository, current) = try await fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let first = ViewDefinition(id: "one", title: "人物工作台", kind: .knowledge, rendererID: "reading.composition", scope: "current", composition: ReadingWorkbench.definition())
        let a = try await repository.ensureReadingComponent(bookID: current.id, sourceHash: current.sourceHash, view: first)
        var next = first; next.id = "two"; next.title = "另一个模型标题"
        let b = try await repository.ensureReadingComponent(bookID: current.id, sourceHash: current.sourceHash, view: next)
        XCTAssertTrue(a.created); XCTAssertFalse(b.created); XCTAssertEqual(b.view.id, "one"); XCTAssertEqual(b.project.views.count, 1)
        XCTAssertEqual(b.project.entities, current.entities); XCTAssertEqual(b.project.events, current.events)
    }
    func testWorkbenchContinuedRangeAddsNewSharedRecordsWithoutDuplicatingOldOnes() throws {
        var current = try edit(book())
        let small = try ReadingQuerySnapshot.freeze(scope: .readSoFar, in: current, context: .init(unitID: "u1", page: 1))
        let first = try CompositionRuntime.project(CompositionRuntime.prepare(ReadingWorkbench.definition(), in: current, sourceSnapshot: small))
        current.entities.append(.init(id: "new", typeID: "person", name: "来意", evidence: [.init(unitID: "u2", quote: current.units[1].text)]))
        let wider = try ReadingQuerySnapshot.freeze(scope: .readSoFar, in: current, context: .init(unitID: "u2", page: 2))
        let second = try CompositionRuntime.project(CompositionRuntime.prepare(ReadingWorkbench.definition(), in: current, sourceSnapshot: wider))
        XCTAssertFalse(first["objects"]!.items.contains { $0.id == "new" }); XCTAssertTrue(second["objects"]!.items.contains { $0.id == "new" })
        XCTAssertEqual(second["objects"]!.items.filter { $0.id == "liu" }.count, 1)
        XCTAssertEqual(second["objects"]!.items.first { $0.id == "liu" }?.summary, "用户自己的理解 e\u{301} 🙂")
        let question = ReadingWorkbench.continuationQuestion(view: .init(id: "wb", title: "我的工作台", kind: .knowledge))
        XCTAssertTrue(question.contains("已有视图ID：wb")); XCTAssertTrue(question.contains("保留我的修正")); XCTAssertTrue(question.contains("处理缺口"))
    }
    func testInvalidEditMetadataIsRejectedRatherThanGrantingHiddenWriteAuthority() throws {
        var current = book(), state = KnowledgeUserEditState()
        state.records = [.init(kind: .entity, objectID: "liu", fields: ["evidence"], basis: .checkedSource)]
        current.knowledgeUserEdits = state; XCTAssertThrowsError(try KnowledgeUserEditsRuntime.validate(in: current))
        state.records[0].fields = ["summary", "summary"]; current.knowledgeUserEdits = state
        XCTAssertThrowsError(try KnowledgeUserEditsRuntime.validate(in: current))
    }
    func testReviewedSupplementSurvivesRealChatCommitButRejectsLaterUserCorrection() async throws {
        let (root, repository, original) = try await fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let grant = try await repository.issueChangeGrant(bookID: original.id, permissions: [.knowledge], allowedUnitIDs: ["u1", "u2"], requiresReceipts: false, reason: "继续补充")
        var entity = original.entities[0]; entity.evidence = [.init(unitID: "u2", quote: original.units[1].text)]
        let proposal = try await repository.prepareChanges(.init(knowledge: .init(entities: [entity])), grant: grant)
        XCTAssertTrue(proposal.requiresConfirmation)
        var answered = original; answered.chats.append(.init(role: "assistant", content: "请审阅补充提案。"))
        let withAnswer = try await repository.commitAIResult(base: original, result: answered, operationID: "answer-regression")
        XCTAssertTrue(withAnswer.appliedOperationIDs.contains("answer-regression"))
        let approval = try await repository.approveChanges(proposalID: proposal.id, digest: proposal.digest)
        let committed = try await repository.commitChanges(proposalID: proposal.id, grant: grant, approval: approval)
        XCTAssertEqual(committed.project.entities[0].evidence.count, 2)
        XCTAssertEqual(committed.project.chats.last?.content, "请审阅补充提案。")
        let secondGrant = try await repository.issueChangeGrant(bookID: original.id, permissions: [.knowledge], allowedUnitIDs: ["u1"], requiresReceipts: false, reason: "对照冲突")
        var guan = committed.project.entities[1]; guan.summary = "AI 补充"
        let second = try await repository.prepareChanges(.init(knowledge: .init(entities: [guan])), grant: secondGrant)
        var corrected = committed.project.entities[1]; corrected.summary = "后来手动修正"
        _ = try await repository.saveKnowledgeEdit(bookID: original.id, sourceHash: original.sourceHash, expected: .entity(committed.project.entities[1]), replacement: .entity(corrected), basis: .interpretation)
        let secondApproval = try await repository.approveChanges(proposalID: second.id, digest: second.digest)
        do { _ = try await repository.commitChanges(proposalID: second.id, grant: secondGrant, approval: secondApproval); XCTFail("A real user edit must still conflict") } catch {}
    }
    func testTeacherBackgroundAndSavedReuseKeepReaderJudgmentSeparateFromSourceFacts() throws {
        let original = book(), edited = try edit(original)
        let before = try TeacherBackgroundRequest.freeze(objectID: "liu", in: original, currentUnitID: "u1", avoidsSpoilers: true)
        let after = try TeacherBackgroundRequest.freeze(objectID: "liu", in: edited, currentUnitID: "u1", avoidsSpoilers: true)
        XCTAssertNotEqual(before.contextFingerprint, after.contextFingerprint)
        XCTAssertTrue(after.knownFacts.contains("仅适用于这些字段：summary")); XCTAssertTrue(after.knownFacts.contains("读者修正（我的理解")); XCTAssertTrue(after.knownFacts.contains("不能当作原文明载"))
        let reuse = try XCTUnwrap(SavedKnowledgeReuse(project: edited, currentUnitIDs: ["u2"]))
        let saved = try XCTUnwrap(reuse.record(id: "liu"))
        XCTAssertEqual((saved["readerCorrection"] as? [String: Any])?["basis"] as? String, "我的理解")
        XCTAssertEqual(saved["summary"] as? String, edited.entities[0].summary)
    }
    func testSharedCorrectionsSurviveProjectExportAndImportWithNoExtraComponentDatabase() async throws {
        let (root, repository, original) = try await fixture(); defer { try? FileManager.default.removeItem(at: root) }
        var entity = original.entities[0]; entity.summary = "迁移也保留的个人理解"
        let saved = try await repository.saveKnowledgeEdit(bookID: original.id, sourceHash: original.sourceHash, expected: .entity(original.entities[0]), replacement: .entity(entity), basis: .interpretation)
        let path = root.appendingPathComponent("export.readingbook")
        try await repository.exportProject(saved, to: path)
        let imported = try await repository.importProject(from: path)
        XCTAssertEqual(imported.knowledgeUserEdits, saved.knowledgeUserEdits); XCTAssertEqual(imported.entities, saved.entities)
        XCTAssertEqual(imported.sourceHash, saved.sourceHash); XCTAssertNotEqual(imported.id, saved.id)
        let json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(imported.knowledgeUserEdits)) as! [String: Any]
        XCTAssertEqual(Set(json.keys), ["version", "records"])
    }
}
