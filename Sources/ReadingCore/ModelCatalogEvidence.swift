import Foundation
import CoreFoundation

extension ModelCatalogValidation {
    static func containsExactModelID(_ text: String, modelID: String) -> Bool {
        text.range(of: "(?<![a-zA-Z0-9_./:+-])" + NSRegularExpression.escapedPattern(for: modelID) + "(?![a-zA-Z0-9_./:+-])", options: .regularExpression) != nil
    }
    /// A number elsewhere on a page, in another model, or under another field
    /// never proves this exact model's limit.
    static func limitIsProven(providerID: String, modelID: String, field: String, value: Int, limitSourceURL: String?,
                              sources: [[String: Any]], evidence: [CatalogPublicEvidence]) -> Bool {
        sources.contains { source in
            guard let url = source["url"] as? String, limitSourceURL == nil || limitSourceURL == url,
                  let quote = source["quote"] as? String, containsExactModelID(quote, modelID: modelID) else { return false }
            let reads = evidence.filter { $0.url == url && compact($0.text).contains(compact(quote)) }
            guard !reads.isEmpty else { return false }
            if url == "https://models.dev/api.json" {
                // Same IDs can have different limits on a gateway and direct
                // provider. Resolve the namespace in the actual read JSON.
                return reads.contains { read in
                    guard let root = json(read.text) as? [String: Any], let provider = root[providerID] as? [String: Any] else { return false }
                    return recordLimits(provider, modelID: modelID, field: field) == [value]
                        && quoteProves(quote, modelID: modelID, field: field, value: value)
                }
            }
            return quoteProves(quote, modelID: modelID, field: field, value: value)
        }
    }
    private static func json(_ value: String) -> Any? { try? JSONSerialization.jsonObject(with: Data(value.utf8), options: [.fragmentsAllowed]) }
    private static func quoteProves(_ quote: String, modelID: String, field: String, value: Int) -> Bool {
        if let object = json(quote) {
            // A quoted structured row must identify the exact model. Multiple
            // conflicting records remain uncertain instead of picking a number.
            return recordLimits(object, modelID: modelID, field: field) == [value]
        }
        let escapedID = NSRegularExpression.escapedPattern(for: modelID)
        let idPattern = "(?<![a-zA-Z0-9_./:+-])" + escapedID + "(?![a-zA-Z0-9_./:+-])"
        let label = field == "contextTokens"
            ? "(?i)\\b(?:context(?:[_ ]*(?:window|length|tokens))?|window)\\b[^0-9\\r\\n]{0,48}([0-9][0-9,]*)"
            : "(?i)\\b(?:max(?:imum)?[_ ]+(?:completion[_ ]+)?(?:output(?:[_ ]+tokens)?|tokens)|output(?:[_ ]+(?:limit|tokens))?|max_completion_tokens|max_tokens)\\b[^0-9\\r\\n]{0,48}([0-9][0-9,]*)"
        guard let ids = try? NSRegularExpression(pattern: idPattern), let values = try? NSRegularExpression(pattern: label) else { return false }
        // Plain assertions have to be a single explicit model row. JSON and
        // multi-row tables should be quoted as exact structured records instead.
        return quote.components(separatedBy: .newlines).contains { line in
            let range = NSRange(line.startIndex..<line.endIndex, in: line)
            let matches = ids.matches(in: line, range: range)
            guard matches.count == 1, let idRange = Range(matches[0].range, in: line) else { return false }
            let suffix = String(line[idRange.upperBound...])
            guard suffix.range(of: "(?i)\\bmodel\\s+[a-z0-9][a-z0-9_./:+-]*", options: .regularExpression) == nil else { return false }
            let contextPattern = "(?i)\\b(?:context(?:[_ ]*(?:window|length|tokens))?|window)\\b[^0-9\\r\\n]{0,48}([0-9][0-9,]*)"
            let outputPattern = "(?i)\\b(?:max(?:imum)?[_ ]+(?:completion[_ ]+)?(?:output(?:[_ ]+tokens)?|tokens)|output(?:[_ ]+(?:limit|tokens))?|max_completion_tokens|max_tokens)\\b[^0-9\\r\\n]{0,48}([0-9][0-9,]*)"
            var residue = suffix.replacingOccurrences(of: contextPattern, with: " ", options: .regularExpression)
            residue = residue.replacingOccurrences(of: outputPattern, with: " ", options: .regularExpression)
            residue = residue.replacingOccurrences(of: "(?i)\\b(?:has|have|a|an|and|of|the|tokens?|is|with|supports|up|to|at|most|total|shared)\\b", with: " ", options: .regularExpression)
            residue = residue.trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
            guard residue.isEmpty else { return false }
            let found = values.matches(in: suffix, range: NSRange(suffix.startIndex..<suffix.endIndex, in: suffix))
            guard found.count == 1, let number = Range(found[0].range(at: 1), in: suffix) else { return false }
            return Int(suffix[number].replacingOccurrences(of: ",", with: "")) == value
        }
    }
    private static func recordLimits(_ object: Any, modelID: String, field: String) -> Set<Int> {
        if let rows = object as? [Any] { return rows.reduce(into: Set<Int>()) { $0.formUnion(recordLimits($1, modelID: modelID, field: field)) } }
        guard let dictionary = object as? [String: Any] else { return [] }
        if let models = dictionary["models"] { return recordLimits(models, modelID: modelID, field: field) }
        if let id = dictionary["id"] as? String {
            guard id == modelID else { return [] }
            if let value = limit(in: dictionary, field: field) { return [value] }
            return []
        }
        if let exact = dictionary[modelID] as? [String: Any], let value = limit(in: exact, field: field) { return [value] }
        return dictionary.values.reduce(into: Set<Int>()) { $0.formUnion(recordLimits($1, modelID: modelID, field: field)) }
    }
    private static func limit(in record: [String: Any], field: String) -> Int? {
        let value: Any?
        if let limits = record["limit"] as? [String: Any] { value = limits[field == "contextTokens" ? "context" : "output"] }
        else if let top = record["top_provider"] as? [String: Any] {
            let preferred = top[field == "contextTokens" ? "context_length" : "max_completion_tokens"]
            value = field == "contextTokens" && (preferred == nil || preferred is NSNull) ? record["context_length"] : preferred
        } else { value = record[field == "contextTokens" ? "contextTokens" : "maxOutputTokens"] ?? (field == "contextTokens" ? record["context_length"] : nil) }
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(), number.doubleValue.isFinite,
              number.doubleValue.rounded() == number.doubleValue, number.doubleValue >= 0, number.doubleValue <= 4_194_304 else { return nil }
        return number.intValue
    }
}
