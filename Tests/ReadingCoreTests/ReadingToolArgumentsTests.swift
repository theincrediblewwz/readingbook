import Foundation
import XCTest
@testable import ReadingCore

actor ArgumentRepairHost {
    var calls = [String]()
    func open(_ name: String, _ data: Data) throws -> Data {
        calls.append(name)
        let arguments = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        return try JSONSerialization.data(withJSONObject: ["ok": true, "status": "success", "opened": true,
            "viewID": arguments["viewID"] ?? "", "created": false])
    }
}
final class ArgumentProgressProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [AIProgressEvent] = []
    func append(_ value: AIProgressEvent) { lock.lock(); defer { lock.unlock() }; values.append(value) }
    var count: Int { lock.lock(); defer { lock.unlock() }; return values.count }
    var snapshot: [AIProgressEvent] { lock.lock(); defer { lock.unlock() }; return values }
}

final class ReadingToolArgumentsTests: XCTestCase {
    private func failure(_ raw: String) throws -> ReadingToolArgumentError {
        do { _ = try ReadingToolArguments.parse(Data(raw.utf8), maximumBytes: 262_144); XCTFail("invalid JSON accepted") }
        catch let error as ReadingToolArgumentError { return error }
        throw ReadingError.invalid("Missing argument error")
    }
    func testUnicodeSyntaxFailureHasCorrectLineColumnAndDelimiter() throws {
        let raw = "{\n\"名字\":\"雪山🌲\",\"资料\":[{\"种类\":\"调查\"}}}"
        let error = try failure(raw), issue = try XCTUnwrap(error.issues.first)
        XCTAssertEqual(issue["line"] as? Int, 2)
        XCTAssertEqual(issue["expected"] as? String, "]")
        XCTAssertEqual(issue["actual"] as? String, "}")
        XCTAssertEqual(issue["column"] as? Int, raw.split(separator: "\n")[1].unicodeScalars.count - 1)
        XCTAssertEqual(error.rawArguments, Data(raw.utf8))
        XCTAssertTrue((issue["near"] as? String)?.contains("雪山🌲") == true)
    }
    func testDelimiterHintIgnoresBracketsAndEscapedQuotesInsideStrings() throws {
        let raw = #"{"text":"[不是数组] \"{\"","rows":[1}"#
        let issue = try XCTUnwrap(try failure(raw).issues.first)
        XCTAssertEqual(issue["expected"] as? String, "]")
        let missing = try XCTUnwrap(try failure(#"{"text":"结尾"#).issues.first)
        XCTAssertEqual(missing["actual"] as? String, "end_of_input")
        XCTAssertEqual(missing["expected"] as? String, "\"")
    }
    func testNonDelimiterJSONErrorIsStillReportedWithoutInventedPosition() throws {
        let issue = try XCTUnwrap(try failure(#"{"value":wrong}"#).issues.first)
        XCTAssertEqual(issue["kind"] as? String, "json_syntax")
        XCTAssertNil(issue["line"]); XCTAssertNotNil(issue["reason"])
    }
    func testDuplicateKeysAreRejectedBeforeLastValueCanReplaceTheFirst() throws {
        let raw = "{\n\"markerAssets\":{\"map\":{\"设备转运\":\"event\",\"设备转运\":\"transport\"}}}"
        let error = try failure(raw), issue = try XCTUnwrap(error.issues.first)
        XCTAssertEqual(issue["kind"] as? String, "duplicate_key")
        XCTAssertEqual(issue["key"] as? String, "设备转运"); XCTAssertEqual(issue["line"] as? Int, 2)
        XCTAssertEqual(error.rawArguments, Data(raw.utf8)); XCTAssertNotNil(issue["column"])
        let draft = ReadingToolDraft(tool: "component_show", arguments: error.rawArguments!, rawJSON: true)
        let corrected = try draft.applying(["draftID": draft.id, "textEdits": [[
            "before": "\"设备转运\":\"event\",\"设备转运\":\"transport\"", "after": "\"设备转运\":\"transport\""]]])
        let maps = try XCTUnwrap(corrected["markerAssets"] as? [String: [String: String]])
        XCTAssertEqual(maps, ["map": ["设备转运": "transport"]])
        XCTAssertThrowsError(try draft.applying(["draftID": draft.id, "textEdits": [["before": "event", "after": "observation"]]]))
    }
    func testDuplicateKeyScanSeparatesObjectsAndDecodesEscapedKeysOnly() throws {
        let raw = #"{"a":1,"\u0061":2}"#
        XCTAssertEqual(try failure(raw).issues.first?["key"] as? String, "a")
        let legal = #"{"rows":[{"a":1},{"a":2}],"a":"a\":{}[]\"","nested":{"a":3},"quoted\"key":4}"#
        let parsed = try ReadingToolArguments.parse(Data(legal.utf8), maximumBytes: 32_768)
        XCTAssertEqual((parsed["rows"] as? [[String: Int]])?.count, 2)
        XCTAssertEqual(parsed["quoted\"key"] as? Int, 4)
        XCTAssertEqual(try failure(#"{"a/b~c":1,"a\/b~c":2}"#).issues.first?["key"] as? String, "a/b~c")
        XCTAssertThrowsError(try ReadingToolArguments.parse(Data(legal.utf8), maximumBytes: 8))
    }
    func testRawRepairWorksAcrossTopicsAndPreservesAllOtherData() throws {
        for title in ["植物调查", "城市维护", "Field notes", "急救记录🌲"] {
            let valid: [String: Any] = ["title": title, "rows": [["details": "保留这一段文字", "values": [1,2,3]]]]
            let data = try JSONSerialization.data(withJSONObject: valid, options: [.sortedKeys])
            var raw = String(decoding: data, as: UTF8.self)
            raw.removeLast(); raw += "]"
            let draft = ReadingToolDraft(tool: "knowledge_changes_propose", arguments: Data(raw.utf8), rawJSON: true)
            let before = String(raw.suffix(40)), after = String(before.dropLast()) + "}"
            let repaired = try draft.applying(["draftID": draft.id, "textEdits": [["before": before, "after": after]]])
            XCTAssertTrue(NSDictionary(dictionary: repaired).isEqual(to: valid))
            XCTAssertEqual(draft.arguments, Data(raw.utf8))
        }
    }
    func testClosingSuggestionRepairsMissingAndMisplacedSuffixWithoutChangingValues() throws {
        let value: [String: Any] = ["batch": ["knowledge": ["rows": [["spatial": ["kind": "独立分类", "literal": "方括号 ] 与引号 \\\" 均是正文"]]]]]]
        let good = String(decoding: try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]), as: UTF8.self)
        var prefix = good
        while prefix.last == "}" || prefix.last == "]" { prefix.removeLast() }
        for badEnding in ["}}}}}", "}}}]}}}", "", "]]]}}"] {
            let raw = prefix + badEnding, error = try failure(raw)
            let edits = try XCTUnwrap(error.issues.first?["suggestedTextEdits"] as? [[String: String]])
            let draft = ReadingToolDraft(tool: "knowledge_changes_propose", arguments: Data(raw.utf8), rawJSON: true)
            let corrected = try draft.applying(["draftID": draft.id, "textEdits": edits])
            XCTAssertTrue(NSDictionary(dictionary: corrected).isEqual(to: value))
        }
        XCTAssertNil(try failure(#"{"value":wrong}"#).issues.first?["suggestedTextEdits"])
        XCTAssertNil(try failure(#"{"value":"missing quote"#).issues.first?["suggestedTextEdits"])
    }
    func testRawRepairRejectsAmbiguityOverlapAndMissingText() throws {
        let draft = ReadingToolDraft(tool: "component_show", arguments: Data(#"{"title":"aaaa","value":"aaaa""#.utf8), rawJSON: true)
        for before in ["aaaa", "aaa", "missing"] {
            XCTAssertThrowsError(try draft.applying(["draftID": draft.id, "textEdits": [["before": before, "after": "b"]]]))
        }
        XCTAssertThrowsError(try draft.applying(["draftID": draft.id, "edits": [["operation": "set", "path": "/title", "value": "b"]]]))
        XCTAssertThrowsError(try draft.applying(["draftID": draft.id, "targetTool": "book_scheme_propose", "textEdits": [["before": "missing", "after": "b"]]]))
    }
    func testRawRepairAcceptsSchemaPermittedOriginalToolButCannotRetarget() throws {
        let draft = ReadingToolDraft(tool: "knowledge_changes_propose", arguments: Data(#"{"rows":[1}"#.utf8), rawJSON: true)
        let edit = [["before": "[1}", "after": "[1]}"]]
        let repaired = try draft.applying(["draftID": draft.id, "targetTool": draft.tool, "textEdits": edit])
        XCTAssertEqual(repaired["rows"] as? [Int], [1])
        for target in ["book_scheme_propose", "component_show", "source_read", ""] {
            XCTAssertThrowsError(try draft.applying(["draftID": draft.id, "targetTool": target, "textEdits": edit]))
        }
        XCTAssertThrowsError(try draft.applying(["draftID": draft.id, "targetTool": NSNull(), "textEdits": edit]))
        XCTAssertEqual(String(decoding: draft.arguments, as: UTF8.self), #"{"rows":[1}"#)
    }
    func testRawRepairCannotExpandBeyondToolSizeOrUnlimitedPatch() throws {
        let draft = ReadingToolDraft(tool: "component_show", arguments: Data(("{\"value\":\"" + String(repeating: "x", count: 32_700) + "\"}").utf8), rawJSON: true)
        XCTAssertThrowsError(try draft.applying(["draftID": draft.id, "textEdits": [["before": "{", "after": "{\"extra\":\"" + String(repeating: "y", count: 1000) + "\","]]]))
        XCTAssertThrowsError(try draft.applying(["draftID": draft.id, "textEdits": [["before": "", "after": "}"]]]))
    }
    func testTypedFieldErrorsReturnOriginalWrappedAndUnwrappedPointers() throws {
        for wrapped in [true, false] {
            let raw = wrapped ? #"{"batch":{"knowledge":{"newEntityIDs":[42]}}}"# : #"{"newEntityIDs":[42]}"#
            do { _ = try ReadingProposalTools.decode(name: "knowledge_changes_propose", arguments: Data(raw.utf8)); XCTFail("type mismatch accepted") }
            catch let error as ReadingToolArgumentError {
                XCTAssertEqual(error.issues.first?["path"] as? String, wrapped ? "/batch/knowledge/newEntityIDs/0" : "/newEntityIDs/0")
                XCTAssertEqual(error.issues.first?["actualType"] as? String, "number")
                XCTAssertEqual(error.issues.first?["expected"] as? String, "String")
                XCTAssertNil(error.rawArguments)
            }
        }
    }
    private func project() throws -> BookProject {
        var value = BookProject(title: "调查", originalName: "input.txt", sourceHash: "bounded",
            units: [.init(id: "source", order: 0, chapter: "第一段", text: "只分享这一段。")])
        PluginEngine.seed(&value)
        value.views = [.init(id: "view-a", title: "工作台", kind: .knowledge, rendererID: "reading.composition",
            composition: ReadingWorkbench.definition(for: ReadingWorkbench.timeMapTemplateID))]
        return value
    }
    func testRawDraftRequiresExistingGrantAndKeepsSuccessiveSyntaxEdits() throws {
        let book = try project(), snapshot = try ReadingQuerySnapshot.freeze(scope: .book, in: book)
        var denied = ReadingQuerySession(snapshot: snapshot, history: [], loader: nil, providedDocuments: [:], project: book)
        let raw = Data(#"{"viewID":"wrong","rows":[1}"#.utf8)
        denied.retainRejectedRawDraft(name: "component_show", arguments: raw)
        XCTAssertNil(denied.rejectedToolDraft)
        let host = ReadingHostToolAccess(viewActions: ["component_show"], performViewAction: { _, _ in Data() })
        var session = ReadingQuerySession(snapshot: snapshot, history: [], loader: nil, providedDocuments: [:], project: book, hostTools: host)
        session.retainRejectedRawDraft(name: "component_show", arguments: raw)
        let first = try XCTUnwrap(session.rejectedToolDraft)
        XCTAssertThrowsError(try session.resolveToolDraft(name: "tool_draft_repair", arguments: ["draftID": first.id,
            "textEdits": [["before": "wrong", "after": "view-a"]]]))
        let second = try XCTUnwrap(session.rejectedToolDraft)
        XCTAssertNotEqual(first.id, second.id)
        XCTAssertTrue(String(decoding: second.arguments, as: UTF8.self).contains("view-a"))
        let (_, arguments) = try session.resolveToolDraft(name: "tool_draft_repair", arguments: ["draftID": second.id,
            "textEdits": [["before": "[1}", "after": "[1]}"]]])
        XCTAssertEqual(arguments["viewID"] as? String, "view-a")
        XCTAssertEqual(arguments["rows"] as? [Int], [1])
    }
    func testEngineReturnsSyntaxDraftAndRepairsThroughOriginalHost() async throws {
        for (raw, before, after) in [
            (#"{"viewID":"view-a""#, #""view-a""#, #""view-a"}"#),
            (#"{"viewID":"wrong","viewID":"view-a"}"#, #""viewID":"wrong","viewID":"view-a""#, #""viewID":"view-a""#)
        ] {
        let book = try project(), host = ArgumentRepairHost()
        let access = ReadingHostToolAccess(viewActions: ["component_show"], performViewAction: { try await host.open($0,$1) },
            readWorkspaceAfterOpening: { id in .init(bookID: book.id, sourceHash: book.sourceHash, rendererID: id) })
        var round = 0
        let progressValues = ArgumentProgressProbe()
        let answer = try await ReadingAnswerEngine.run(question: "打开已有工作台", project: book,
            settings: .init(model: "offline", maxOutputTokens: 512, contextWindowTokens: 128_000), documents: [:],
            context: nil, scope: .book, history: [], memory: nil, memoryEnabled: false, documentIDs: nil,
            loader: nil, operationLimit: 128_000, remainingRequests: 4, hostTools: access,
            progress: { progressValues.append($0) }, preferences: .init(interaction: .functional)) { messages, _, _, _ in
                round += 1
                if round == 3 { return .init(message: .init(role: "assistant", content: "已打开工作台。", refusal: nil, tool_calls: nil, reasoning_content: nil), finishReason: "stop", tokenCost: 30) }
                let name: String, arguments: String
                if round == 1 { name = "component_show"; arguments = raw }
                else {
                    let receipt = try JSONSerialization.jsonObject(with: Data((messages.last?["content"] as! String).utf8)) as! [String: Any]
                    XCTAssertNotNil(receipt["argumentIssues"]); XCTAssertNil(receipt["referenceGuide"])
                    let repair = try XCTUnwrap(receipt["repair"] as? [String: Any])
                    XCTAssertEqual(repair["format"] as? String, "json_text")
                    name = "tool_draft_repair"
                    arguments = String(decoding: try JSONSerialization.data(withJSONObject: ["draftID": repair["draftID"]!, "textEdits": [["before": before, "after": after]]]), as: UTF8.self)
                }
                return .init(message: .init(role: "assistant", content: "", refusal: nil, tool_calls: [.init(id: "call-\(round)", type: "function", function: .init(name: name, arguments: arguments))], reasoning_content: nil), finishReason: "tool_calls", tokenCost: 30)
            }
        XCTAssertEqual(answer.message.content, "已打开工作台。")
        let applied = await host.calls; XCTAssertEqual(applied, ["component_show"])
        XCTAssertEqual(round, 3)
        XCTAssertGreaterThan(progressValues.count, 0)
        let completed = progressValues.snapshot.filter { $0.phase == .toolCompleted }
        XCTAssertEqual(completed.count, 2)
        XCTAssertEqual(completed.first?.toolSucceeded, false)
        XCTAssertEqual(completed.last?.toolSucceeded, true)
        XCTAssertNotNil(completed.first?.toolTrace)
        }
    }
    func testAdmittedNestedFamiliesMergeAtDistanceAndSeparateWhenZoomed() throws {
        for prefix in ["救援", "调查", "travel"] {
            let ids = Set((0..<7).map { prefix + String($0) })
            let parents = [prefix+"1": prefix+"0", prefix+"2": prefix+"0", prefix+"3": prefix+"1",
                           prefix+"4": prefix+"1", prefix+"5": prefix+"2", prefix+"6": prefix+"2"]
            let roots = SpatialMarkerSeeds.familyRoots(eventIDs: ids, parents: parents)
            XCTAssertEqual(Set(roots.values), [prefix+"0"])
            func markers(_ scale: Double, roots: [String: String]) -> [SpatialMarkerScreenPoint] {
                ids.sorted().enumerated().map { index, id in
                    .init(seed: .init(id: id, objectID: id, title: id, coordinate: .init(latitude: 30, longitude: 110),
                                     assetID: "event", affinityID: roots[id], affinityTitle: roots[id]),
                          x: 100 + Double(index) * scale, y: 100)
                }
            }
            let old = SpatialMarkerPacking.layout(markers(1, roots: parents), width: 1200, height: 600)
            let far = SpatialMarkerPacking.layout(markers(1, roots: roots), width: 1200, height: 600)
            let near = SpatialMarkerPacking.layout(markers(100, roots: roots), width: 1200, height: 600)
            XCTAssertEqual(old.nodes.count, 4); XCTAssertEqual(far.nodes.count, 1); XCTAssertEqual(near.nodes.count, 7)
            XCTAssertEqual(Set(far.nodes.flatMap(\.members).map(\.id)), ids)
        }
    }
    func testFamilyGroupingNeverReadsOutsideAdmissionOrInventsCycleHierarchy() {
        let ids: Set<String> = ["a","b","c","outside-child","cycle-1","cycle-2"]
        let roots = SpatialMarkerSeeds.familyRoots(eventIDs: ids, parents: ["b":"a","c":"b", "a":"unshared", "outside-child":"unshared", "cycle-1":"cycle-2","cycle-2":"cycle-1"])
        XCTAssertEqual(roots["a"], "a"); XCTAssertEqual(roots["c"], "a")
        XCTAssertNil(roots["unshared"]); XCTAssertNil(roots["outside-child"])
        XCTAssertNil(roots["cycle-1"]); XCTAssertNil(roots["cycle-2"])
    }
}
