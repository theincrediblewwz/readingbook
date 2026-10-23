import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// Has no cookies, authorization headers, profile access, or mutation capability.
public struct ModelCatalogPublicReader: Sendable {
    public static let officialHosts: Set<String> = [
        "opencode.ai", "models.dev", "openrouter.ai", "api-docs.deepseek.com", "help.aliyun.com",
        "platform.kimi.com", "platform.moonshot.cn", "docs.bigmodel.cn", "docs.volcengine.com",
        "www.volcengine.com", "mimo.mi.com", "developers.openai.com", "platform.openai.com",
        "ai.google.dev", "docs.anthropic.com", "platform.claude.com", "platform.minimaxi.com", "docs.siliconflow.cn"
    ]
    private let addedURLs: Set<String>
    /// Only the host UI may provide these exact, user-entered public links.
    public init(additionalOfficialURLs: [String] = []) throws {
        guard additionalOfficialURLs.count <= 8 else { throw ReadingError.invalid("一次最多添加8个官方资料链接。") }
        addedURLs = Set(try additionalOfficialURLs.map { try ModelCatalogValidation.publicURL($0).absoluteString })
    }
    public func allows(_ address: String) -> Bool {
        guard let url = try? ModelCatalogValidation.publicURL(address), let host = url.host?.lowercased() else { return false }
        return Self.officialHosts.contains(host) || addedURLs.contains(url.absoluteString)
    }
    public func read(_ address: String) async throws -> CatalogPublicEvidence {
        guard allows(address) else { throw ReadingError.invalid("此资料域名不在允许范围。新官网链接需由读者显式添加。") }
        let url = try ModelCatalogValidation.publicURL(address)
        try Task.checkCancellation()
        try await Task.detached(priority: .utility) { try Self.checkPublicDNS(url.host ?? "") }.value
        try Task.checkCancellation()
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 20)
        request.setValue("ReadingBook-Catalog/0.15", forHTTPHeaderField: "User-Agent")
        request.setValue("text/html,application/json,text/plain", forHTTPHeaderField: "Accept")
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil; configuration.httpCookieStorage = nil; configuration.urlCredentialStorage = nil
        configuration.httpShouldSetCookies = false; configuration.timeoutIntervalForRequest = 20; configuration.timeoutIntervalForResource = 25
        let (data, _) = try await BoundedProviderResponse.read(request, configuration: configuration)
        guard data.count <= 4 * 1024 * 1024, let raw = String(data: data, encoding: .utf8) else { throw ReadingError.invalid("公共资料过大或不是UTF-8文本。") }
        let text = Self.pageText(raw)
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw ReadingError.invalid("未读取到可核对的公共正文。") }
        return CatalogPublicEvidence(url: url.absoluteString, text: text)
    }
    public static func pageText(_ raw: String) -> String {
        guard raw.range(of: "<[a-zA-Z!/]", options: .regularExpression) != nil else { return raw }
        var result = raw.replacingOccurrences(of: "(?is)<(script|style|svg|nav|footer)\\b[^>]*>.*?</\\1>", with: " ", options: .regularExpression)
        result = result.replacingOccurrences(of: "(?is)<[^>]*>", with: " ", options: .regularExpression)
        for (entity, value) in [("&quot;", "\""), ("&#39;", "'"), ("&#x27;", "'"), ("&nbsp;", " "), ("&lt;", "<"), ("&gt;", ">"), ("&amp;", "&")] {
            result = result.replacingOccurrences(of: entity, with: value)
        }
        return ModelCatalogValidation.compact(result)
    }
    static func checkPublicDNS(_ host: String) throws {
        var hints = addrinfo()
        hints.ai_family = AF_UNSPEC
        #if os(Linux)
        hints.ai_socktype = Int32(SOCK_STREAM.rawValue)
        #else
        hints.ai_socktype = SOCK_STREAM
        #endif
        var head: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, "443", &hints, &head) == 0, let first = head else { throw ReadingError.invalid("公共资料域名无法解析。") }
        defer { freeaddrinfo(first) }
        var next: UnsafeMutablePointer<addrinfo>? = first
        while let entry = next {
            var numeric = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(entry.pointee.ai_addr, entry.pointee.ai_addrlen, &numeric, socklen_t(numeric.count), nil, 0, NI_NUMERICHOST) == 0,
                  isPublicIP(String(cString: numeric)) else { throw ReadingError.invalid("公共目录不能读取内网或保留地址。") }
            next = entry.pointee.ai_next
        }
    }
    static func isPublicIP(_ address: String) -> Bool {
        if address.contains(":") {
            if address.lowercased().hasPrefix("::ffff:") { return isPublicIP(String(address.dropFirst(7))) }
            guard let first = address.split(separator: ":").first, let value = UInt16(first, radix: 16) else { return false }
            return (value & 0xe000) == 0x2000 && !address.lowercased().hasPrefix("2001:db8:")
        }
        let parts = address.split(separator: ".").compactMap { Int($0) }
        guard parts.count == 4, parts.allSatisfy({ (0...255).contains($0) }) else { return false }
        let a = parts[0], b = parts[1]
        return a != 0 && a != 10 && a != 127 && a < 224 && !(a == 169 && b == 254)
            && !(a == 172 && (16...31).contains(b)) && !(a == 192 && b == 168)
            && !(a == 100 && (64...127).contains(b)) && !(a == 198 && [18, 19, 51].contains(b))
            && !(a == 192 && b == 0) && !(a == 203 && b == 0 && parts[2] == 113)
            && parts != [168, 63, 129, 16]
    }
}
