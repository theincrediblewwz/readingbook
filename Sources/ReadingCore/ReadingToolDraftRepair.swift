import Foundation

/// One rejected, in-memory tool draft per frozen query session. This is not a
/// saved proposal or a write grant. Every repaired draft re-enters the original
/// tool's complete decoder, source checks and host review.
struct ReadingToolDraft {
    let id = UUID().uuidString
    let tool: String
    let arguments: Data

    var offer: [String: Any] {
        ["draftID": id, "tool": tool, "editTool": ReadingQueryToolCatalog.draftRepairName,
         "originalBytes": arguments.count,
         "pathSyntax": "JSON Pointer，例如/batch/knowledge/eventMetadata/0/extent/sourceText或/composition/parts/0/timeGroup。草案只在本次任务内保留；只改错误字段，无需重发其余内容。"]
    }

    func applying(_ request: [String: Any]) throws -> [String: Any] {
        guard Set(request.keys) == ["draftID", "edits"], request["draftID"] as? String == id,
              let edits = request["edits"] as? [[String: Any]], (1...32).contains(edits.count),
              try JSONSerialization.data(withJSONObject: request).count <= 16_384 else {
            throw ReadingError.invalid("局部修正需本次失败草案的draftID和1至32项edits，合计不超过16KiB。")
        }
        var root: Any = try JSONSerialization.jsonObject(with: arguments)
        for edit in edits {
            guard let operation = edit["operation"] as? String, ["set", "remove"].contains(operation),
                  Set(edit.keys) == (operation == "set" ? ["operation", "path", "value"] : ["operation", "path"]),
                  let path = edit["path"] as? String else { throw ReadingError.invalid("每项修正使用set加path/value，或remove加path；不接受其他操作。") }
            let tokens = try Self.tokens(path)
            root = try Self.edit(root, tokens: tokens[...], value: edit["value"], remove: operation == "remove")
        }
        guard let object = root as? [String: Any], try JSONSerialization.data(withJSONObject: object).count <= (tool == "component_show" ? 32_768 : 262_144) else {
            throw ReadingError.invalid("修正后的完整草案超过原工具大小上限；没有执行或保存。")
        }
        return object
    }

    private static func tokens(_ path: String) throws -> [String] {
        guard path.hasPrefix("/"), path.utf8.count <= 512 else { throw ReadingError.invalid("path需为非空JSON Pointer，不能替换整个草案。") }
        let raw = path.dropFirst().split(separator: "/", omittingEmptySubsequences: false)
        guard raw.count <= 16 else { throw ReadingError.invalid("修正字段路径超过16层。") }
        return try raw.map { token in
            var result = "", iterator = token.makeIterator()
            while let character = iterator.next() {
                if character == "~" {
                    guard let escaped = iterator.next(), escaped == "0" || escaped == "1" else { throw ReadingError.invalid("路径中的~须写成~0，字段名中的/须写成~1。") }
                    result.append(escaped == "0" ? "~" : "/")
                } else { result.append(character) }
            }
            return result
        }
    }
    private static func edit(_ current: Any, tokens: ArraySlice<String>, value: Any?, remove: Bool) throws -> Any {
        guard let key = tokens.first else { throw ReadingError.invalid("不能替换整个草案。") }
        let tail = tokens.dropFirst()
        if var object = current as? [String: Any] {
            if tail.isEmpty {
                if remove {
                    guard object.removeValue(forKey: key) != nil else { throw ReadingError.invalid("要删除的草案字段不存在。") }
                } else { object[key] = value }
            } else {
                guard let child = object[key] else { throw ReadingError.invalid("修正路径的上级字段不存在；请填写实际路径。") }
                object[key] = try edit(child, tokens: tail, value: value, remove: remove)
            }
            return object
        }
        if var array = current as? [Any] {
            guard !key.isEmpty, key.allSatisfy({ $0.isASCII && $0.isNumber }), key == "0" || !key.hasPrefix("0"),
                  let index = Int(key), array.indices.contains(index) else { throw ReadingError.invalid("修正路径的数组下标无效；只可修改或删除已有项。") }
            if tail.isEmpty {
                if remove { array.remove(at: index) }
                else if let value { array[index] = value }
            } else { array[index] = try edit(array[index], tokens: tail, value: value, remove: remove) }
            return array
        }
        throw ReadingError.invalid("修正路径穿过了文字、数字或空值；没有执行任何修改。")
    }
}

extension ReadingQueryToolCatalog {
    static let draftRepairName = "tool_draft_repair"
    static var draftRepairSchema: [String: Any] {
        function(draftRepairName, "修正失败回执中repair所指的草案，再交回原工具完整校验与审阅。只提交错误字段，不重发整份提案；不是批准或提交权限，不能修改已保存数据。", [
            "draftID": ["type": "string", "maxLength": 128],
            "edits": ["type": "array", "minItems": 1, "maxItems": 32, "items": ["type": "object", "additionalProperties": false,
                "properties": ["operation": ["type": "string", "enum": ["set", "remove"]],
                    "path": ["type": "string", "maxLength": 512, "description": "JSON Pointer，从/开始，数组用数字下标。set可补对象字段或替换已有值；remove删除已有字段/数组项，同一数组删除从后往前。"],
                    "value": ["description": "set的JSON值，可为文字、数值、对象、数组或null；remove不填。"]], "required": ["operation", "path"]]]
        ], required: ["draftID", "edits"])
    }
}

extension ReadingQuerySession {
    var repairableToolNames: Set<String> {
        (proposalAccess?.proposalTools.intersection(ReadingQueryToolCatalog.proposalNames) ?? [])
            .union(hostTools?.viewActions.contains("component_show") == true ? ["component_show"] : [])
    }
    mutating func resolveToolDraft(name: String, arguments: [String: Any]) throws -> (String, [String: Any]) {
        lastRepairOffer = nil; lastEffectiveTool = nil
        guard name == ReadingQueryToolCatalog.draftRepairName else { lastEffectiveTool = name; return (name, arguments) }
        guard let draft = rejectedToolDraft, arguments["draftID"] as? String == draft.id,
              repairableToolNames.contains(draft.tool) else { throw invalid("失败草案已失效或不属于本次授权；没有调用宿主或写入数据。") }
        do {
            let value = try draft.applying(arguments)
            lastEffectiveTool = draft.tool
            return (draft.tool, value)
        } catch { lastRepairOffer = draft.offer; throw error }
    }
    mutating func retainRejectedDraft(name: String, arguments: [String: Any], error: Error) {
        guard repairableToolNames.contains(name),
              error is ReadingProposalTemporalError || error is ReadingProposalEvidenceError || error is ReadingSourceReferenceError ||
                error is ReadingProposalReferenceError || error is ReadingProposalMetadataError || error is ReadingCompositionError || error is DecodingError,
              let data = try? JSONSerialization.data(withJSONObject: arguments, options: [.sortedKeys]), data.count <= (name == "component_show" ? 32_768 : 262_144) else { return }
        let draft = ReadingToolDraft(tool: name, arguments: data)
        rejectedToolDraft = draft; lastRepairOffer = draft.offer
    }
}
