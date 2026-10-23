import Foundation
import XCTest
@testable import ReadingCore

final class ControlledChangesTests: XCTestCase {
    private func fixture() throws -> (URL, URL, BookProject, LibraryRepository) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ReadingBook-Controlled-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        let source = root.appendingPathComponent("book.txt"), text = "208年，曹操至江陵。"
        try Data(text.utf8).write(to: source)
        var book = BookProject(title: "整理测试", originalName: "book.txt", sourceHash: try BookImporter.sha256(Data(text.utf8)), units: [SourceUnit(id: "u1", order: 0, chapter: "第一章", text: text)])
        PluginEngine.seed(&book)
        return (root, source, book, LibraryRepository(rootURL: root.appendingPathComponent("library")))
    }
    private func package(_ root: URL, _ book: BookProject) -> URL { root.appendingPathComponent("library/books/\(book.id)") }
    private func encode<T: Encodable>(_ value: T) throws -> Data { let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .prettyPrinted]; return try encoder.encode(value) }
    private func newNote(_ alias: String = "draft") -> ControlledChangeBatch {
        ControlledChangeBatch(graph: ControlledGraphChanges(createNodes: [ControlledNodeCreation(clientID: "node-" + alias, title: "概念", documentIDs: [alias])]),
            documents: ControlledDocumentChanges(create: [ControlledDocumentCreation(clientID: alias, title: "笔记", markdown: "# 我的笔记\n\n保留原书引用。")]))
    }

    func testAtomicNewDocumentNodeIdentityReplayAndSameGrantMultipleProposals() async throws {
        let (root, source, book, repository) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        try await repository.create(book, sourceURL: source)
        let grant = try await repository.issueChangeGrant(bookID: book.id, permissions: [.documents, .graph], allowedUnitIDs: ["u1"], requiresReceipts: false, reason: "本次新增")
        let first = try await repository.prepareChanges(newNote(), grant: grant)
        let repeated = try await repository.prepareChanges(newNote(), grant: grant)
        XCTAssertEqual(first.operationID, repeated.operationID); XCTAssertFalse(first.requiresConfirmation)
        let unchanged = try await repository.loadAll()
        XCTAssertTrue(unchanged[0].documents.isEmpty)
        let second = try await repository.prepareChanges(newNote("second"), grant: grant)
        let committed = try await repository.commitChanges(proposalID: first.id, grant: grant)
        let replay = try await repository.commitChanges(proposalID: first.id, grant: grant)
        XCTAssertTrue(replay.replayed); XCTAssertEqual(replay.receipt.operationID, committed.receipt.operationID)
        let after = try await repository.commitChanges(proposalID: second.id, grant: grant)
        XCTAssertEqual(after.project.documents.count, 2); XCTAssertEqual(after.project.nodes.count, 2)
        XCTAssertEqual(after.project.nodes[0].documentIDs, [first.idMap["draft"]!])
        XCTAssertEqual(after.project.nodes[0].targetID, first.idMap["draft"])
        let body = try await repository.readDocument(bookID: book.id, document: after.project.documents[0])
        XCTAssertTrue(body.contains("我的笔记"))
        do { try await repository.save(book); XCTFail("stale routine save must not erase receipts or objects") } catch {}
        let undone = try await repository.undoChanges(bookID: book.id, operationID: second.operationID)
        XCTAssertEqual(undone.project.nodes.count, 1); XCTAssertEqual(undone.project.trashedDocuments.count, 1)
        let twice = try await repository.undoChanges(bookID: book.id, operationID: second.operationID)
        XCTAssertTrue(twice.replayed)
        do { _ = try await repository.commitChanges(proposalID: second.id, grant: grant); XCTFail("undone receipt cannot report active success") } catch {}
    }

    func testChatAdditionsPreservedButExternalLayoutEditInvalidatesTask() async throws {
        let (root, source, book, repository) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        try await repository.create(book, sourceURL: source)
        let grant = try await repository.issueChangeGrant(bookID: book.id, permissions: [.documents, .graph], allowedUnitIDs: [], requiresReceipts: false, reason: "整理")
        let proposal = try await repository.prepareChanges(newNote(), grant: grant)
        var answer = book; answer.chats.append(ChatMessage(role: "assistant", content: "这是问答结果。"))
        try await repository.save(answer)
        let committed = try await repository.commitChanges(proposalID: proposal.id, grant: grant)
        XCTAssertEqual(committed.project.chats.last?.content, "这是问答结果。")
        let pending = try await repository.prepareChanges(newNote("later"), grant: grant)
        var moved = committed.project; moved.nodes[0].x = 420
        try await repository.save(moved)
        do { _ = try await repository.commitChanges(proposalID: pending.id, grant: grant); XCTFail("external layout change must conflict") } catch {}
        let current = (try await repository.loadAll())[0]
        XCTAssertEqual(current.nodes[0].x, 420); XCTAssertEqual(current.documents.count, 1)
    }

    func testExistingMarkdownNeedsExactApprovalAndHashThenUndoRestoresRawBytes() async throws {
        let (root, source, book, repository) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        try await repository.create(book, sourceURL: source)
        let document = DocumentRecord(id: "user-note", title: "我的笔记")
        let saved = try await repository.saveDocument(project: book, document: document, markdown: "原始内容\n")
        let path = package(root, book).appendingPathComponent(document.relativePath)
        let original = Data([0xef, 0xbb, 0xbf]) + Data("原始内容\r\n".utf8)
        try original.write(to: path)
        let grant = try await repository.issueChangeGrant(bookID: book.id, permissions: [.documents], allowedUnitIDs: [], editableDocumentIDs: [document.id], requiresReceipts: false, reason: "允许审阅已有笔记")
        let batch = ControlledChangeBatch(documents: ControlledDocumentChanges(edits: [ControlledDocumentEdit(documentID: document.id, expectedHash: try BookImporter.sha256(original), mode: .replace, markdown: "新内容")]))
        let proposal = try await repository.prepareChanges(batch, grant: grant)
        XCTAssertTrue(proposal.requiresConfirmation); XCTAssertEqual(proposal.documents.first?.before, String(data: original, encoding: .utf8))
        do { _ = try await repository.commitChanges(proposalID: proposal.id, grant: grant); XCTFail("unconfirmed edit") } catch {}
        let approval = try await repository.approveChanges(proposalID: proposal.id, digest: proposal.digest)
        try Data("外部编辑".utf8).write(to: path)
        do { _ = try await repository.commitChanges(proposalID: proposal.id, grant: grant, approval: approval); XCTFail("stale body must not be overwritten") } catch {}
        XCTAssertEqual(try Data(contentsOf: path), Data("外部编辑".utf8))
        try original.write(to: path)
        let committed = try await repository.commitChanges(proposalID: proposal.id, grant: grant, approval: approval)
        XCTAssertEqual(committed.project.activeDocuments.count, 1)
        XCTAssertEqual(committed.project.trashedDocuments.first?.origin, "change-recovery")
        XCTAssertEqual(try Data(contentsOf: path), Data("新内容".utf8))
        let undo = try await repository.undoChanges(bookID: book.id, operationID: proposal.operationID)
        XCTAssertNotNil(undo.receipt.undoneAt); XCTAssertEqual(try Data(contentsOf: path), original)
        // Old callers cannot save their pre-transaction project back over this history.
        do { _ = try await repository.saveDocument(project: saved, document: document, markdown: "旧窗口", expectedContentHash: try BookImporter.sha256(original)); XCTFail("stale history") } catch {}
    }

    func testUndoProtectsLaterMarkdownAndImportedReceiptIsInert() async throws {
        let (root, source, book, repository) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        try await repository.create(book, sourceURL: source)
        let grant = try await repository.issueChangeGrant(bookID: book.id, permissions: [.documents, .graph], allowedUnitIDs: [], requiresReceipts: false, reason: "新增笔记")
        let proposal = try await repository.prepareChanges(newNote(), grant: grant)
        let result = try await repository.commitChanges(proposalID: proposal.id, grant: grant)
        let document = result.project.documents[0], path = package(root, book).appendingPathComponent(result.project.documents[0].relativePath)
        try Data("后来写下的理解".utf8).write(to: path)
        do { _ = try await repository.undoChanges(bookID: book.id, operationID: proposal.operationID); XCTFail("later body edit") } catch {}
        XCTAssertEqual(try Data(contentsOf: path), Data("后来写下的理解".utf8))
        let export = root.appendingPathComponent("copy.readingbook")
        try await repository.exportProject(result.project, to: export)
        let imported = try await repository.importProject(from: export)
        do { _ = try await repository.undoChanges(bookID: imported.id, operationID: proposal.operationID); XCTFail("historical receipt from another book") } catch {}
        let preserved = try await repository.readDocument(bookID: imported.id, document: document)
        XCTAssertEqual(preserved, "后来写下的理解")
    }

    func testKnowledgeAtomicFailureAndReceiptGate() throws {
        let (root, _, book, _) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let evidence = Evidence(unitID: "u1", quote: book.units[0].text)
        let changes = ControlledKnowledgeChanges(entities: [KnowledgeEntity(id: "person-new", typeID: "person", name: "曹操", evidence: [evidence])], newEntityIDs: ["person-new"])
        var candidate = book
        XCTAssertThrowsError(try ControlledKnowledgeRuntime.apply(changes, to: &candidate, allowedUnitIDs: ["u1"], operationID: "host-read"))
        XCTAssertTrue(candidate.entities.isEmpty)
        let grant = ControlledWriteGrant(id: "test-grant", bookID: book.id, sourceHash: book.sourceHash, baseRevision: "revision", grantRevision: 1, permissions: [.knowledge], allowedUnitIDs: ["u1"], editableDocumentIDs: [], requiresReceipts: false, reason: "manual fixture", expiresAt: Date().addingTimeInterval(600))
        let malformed = ControlledChangeBatch(knowledge: ControlledKnowledgeChanges(entities: changes.entities, relations: [KnowledgeRelation(id: "bad", fromID: "person-new", toID: "missing", label: "关联", evidence: [evidence])], newEntityIDs: ["person-new"], newRelationIDs: ["bad"]))
        XCTAssertThrowsError(try ControlledChangeBuilder.prepare(malformed, grant: grant, project: book, documents: [:], proposalID: "preview", operationID: "host", baseRevision: "revision"))
        XCTAssertTrue(book.entities.isEmpty)
    }

    // The on-disk journal fixture represents a crash after one new .md was
    // replaced but before project.json. A second test simulates an external edit.
    private struct BodyMarker: Codable { var documentID: String; var beforeHash: String?; var afterHash: String }
    private struct Marker: Codable {
        var version = 1; var operationID: String; var bookID: String; var beforeMetadataHash: String; var afterMetadataHash: String
        var bodies: [BodyMarker]; var project: BookProject
        var proofOperationID: String? = nil; var proofReceiptHash: String? = nil
    }
    private func stageInterrupted(root: URL, book: BookProject, externalConflict: Bool) throws -> (DocumentRecord, Data, URL) {
        let directory = package(root, book), metadata = directory.appendingPathComponent("project.json")
        let before = try Data(contentsOf: metadata), doc = DocumentRecord(id: "journal-note", title: "恢复笔记")
        var after = book; after.documents.append(doc)
        let afterData = try encode(after), body = Data("完整待恢复正文".utf8), operation = UUID().uuidString
        let staging = directory.appendingPathComponent(".changes-journal/\(operation)")
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        try body.write(to: staging.appendingPathComponent("\(doc.id).md"))
        let marker = Marker(operationID: operation, bookID: book.id, beforeMetadataHash: try BookImporter.sha256(before), afterMetadataHash: try BookImporter.sha256(afterData), bodies: [BodyMarker(documentID: doc.id, beforeHash: nil, afterHash: try BookImporter.sha256(body))], project: after)
        try encode(marker).write(to: staging.appendingPathComponent("transaction.json"))
        let destination = directory.appendingPathComponent(doc.relativePath)
        try (externalConflict ? Data("外部抢先创建".utf8) : body).write(to: destination)
        return (doc, body, staging)
    }
    func testCrashRecoveryFinishesPartialNewDocumentAndKeepsExternalConflict() async throws {
        for conflict in [false, true] {
            let (root, source, book, repository) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
            try await repository.create(book, sourceURL: source)
            let (doc, body, staging) = try stageInterrupted(root: root, book: book, externalConflict: conflict)
            let report = try await repository.loadReport()
            if conflict {
                XCTAssertTrue(report.projects.isEmpty); XCTAssertEqual(report.issues.count, 1)
                XCTAssertEqual(try Data(contentsOf: package(root, book).appendingPathComponent(doc.relativePath)), Data("外部抢先创建".utf8))
                XCTAssertTrue(FileManager.default.fileExists(atPath: staging.appendingPathComponent("transaction.json").path))
                XCTAssertEqual(try Data(contentsOf: staging.appendingPathComponent("\(doc.id).md")), body)
            } else {
                XCTAssertTrue(report.issues.isEmpty); XCTAssertEqual(report.projects.first?.documents.first?.id, doc.id)
                let restored = try await repository.readDocument(bookID: book.id, document: doc)
                XCTAssertEqual(restored, String(data: body, encoding: .utf8))
                XCTAssertFalse(FileManager.default.fileExists(atPath: staging.path))
            }
        }
    }

    func testAlreadyCommittedCleanupMarkerDoesNotReplayOverLaterBodyOrChat() async throws {
        let (root, source, book, repository) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        try await repository.create(book, sourceURL: source)
        let grant = try await repository.issueChangeGrant(bookID: book.id, permissions: [.documents, .graph], allowedUnitIDs: [], requiresReceipts: false, reason: "整理")
        let proposal = try await repository.prepareChanges(newNote(), grant: grant)
        let committed = try await repository.commitChanges(proposalID: proposal.id, grant: grant)
        let directory = package(root, book), document = committed.project.documents[0]
        let originalBody = try Data(contentsOf: directory.appendingPathComponent(document.relativePath))
        let staged = directory.appendingPathComponent(".changes-journal/\(proposal.operationID)")
        try FileManager.default.createDirectory(at: staged, withIntermediateDirectories: true)
        try originalBody.write(to: staged.appendingPathComponent("\(document.id).md"))
        let metadata = try encode(committed.project)
        let marker = Marker(operationID: proposal.operationID, bookID: book.id, beforeMetadataHash: String(repeating: "0", count: 64), afterMetadataHash: try BookImporter.sha256(metadata),
            bodies: [BodyMarker(documentID: document.id, beforeHash: nil, afterHash: try BookImporter.sha256(originalBody))], project: committed.project,
            proofOperationID: proposal.operationID, proofReceiptHash: try ControlledChangeCoding.hash(committed.receipt))
        try encode(marker).write(to: staged.appendingPathComponent("transaction.json"))
        var later = committed.project; later.chats.append(ChatMessage(role: "assistant", content: "提交后新增的回答"))
        try encode(later).write(to: directory.appendingPathComponent("project.json"))
        try Data("提交后外部编辑".utf8).write(to: directory.appendingPathComponent(document.relativePath))
        let recovered = try await repository.loadReport()
        XCTAssertTrue(recovered.issues.isEmpty); XCTAssertEqual(recovered.projects[0].chats.last?.content, "提交后新增的回答")
        XCTAssertEqual(try Data(contentsOf: directory.appendingPathComponent(document.relativePath)), Data("提交后外部编辑".utf8))
        XCTAssertFalse(FileManager.default.fileExists(atPath: staged.path))
        do { _ = try await repository.commitChanges(proposalID: proposal.id, grant: grant); XCTFail("changed body cannot be replayed as active success") } catch {}
    }

    func testCompleteBeforeAndAfterPreviewBytesAreBoundedAcrossOneGrant() async throws {
        let (root, source, book, repository) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        try await repository.create(book, sourceURL: source)
        let first = DocumentRecord(id: "long-first", title: "第一篇长笔记"), second = DocumentRecord(id: "long-second", title: "第二篇长笔记")
        let original = String(repeating: "a", count: 4 * 1_024 * 1_024), replacement = "短替换"
        var saved = try await repository.saveDocument(project: book, document: first, markdown: original)
        saved = try await repository.saveDocument(project: saved, document: second, markdown: original)
        let grant = try await repository.issueChangeGrant(bookID: book.id, permissions: [.documents], allowedUnitIDs: [], editableDocumentIDs: [first.id, second.id], requiresReceipts: false, reason: "审阅完整原文")
        func batch(_ document: DocumentRecord) throws -> ControlledChangeBatch {
            ControlledChangeBatch(documents: ControlledDocumentChanges(edits: [ControlledDocumentEdit(documentID: document.id, expectedHash: try BookImporter.sha256(Data(original.utf8)), mode: .replace, markdown: replacement)]))
        }
        let preview = try await repository.prepareChanges(batch(first), grant: grant)
        XCTAssertEqual(preview.documents.first?.before?.utf8.count, original.utf8.count, "允许的审阅必须保留完整原文。")
        do {
            _ = try await repository.prepareChanges(batch(second), grant: grant)
            XCTFail("Two 4 MiB originals plus their replacements exceed the per-grant preview budget.")
        } catch ControlledChangeError.denied(let message) { XCTAssertTrue(message.contains("8 MiB")) }
        let unchanged = try await repository.loadAll()
        XCTAssertNil(unchanged[0].controlledChanges)
        XCTAssertEqual(try Data(contentsOf: package(root, book).appendingPathComponent(second.relativePath)).count, original.utf8.count)
        await repository.revokeChangeGrant(grant.id)
        let next = try await repository.issueChangeGrant(bookID: book.id, permissions: [.documents], allowedUnitIDs: [], editableDocumentIDs: [second.id], requiresReceipts: false, reason: "缩小任务")
        let narrower = try await repository.prepareChanges(batch(second), grant: next)
        XCTAssertEqual(narrower.documents.first?.before?.utf8.count, original.utf8.count)
    }
}
