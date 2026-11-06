import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Only fixed, host-written messages leave the transport. Provider error bodies
/// can echo credentials or book text, so neither they nor arbitrary headers are
/// retained in this value or shown to a reader.
struct ProviderHTTPFailure: Error, LocalizedError, Equatable, Sendable {
    enum Reason: Equatable, Sendable { case overloaded, rateLimited, quota, unauthorized, forbidden, unavailable, request }
    let statusCode: Int
    let reason: Reason
    let retryAfterSeconds: Int?

    init(response: HTTPURLResponse, body: Data = Data(), now: Date = Date()) {
        statusCode = response.statusCode
        retryAfterSeconds = Self.retryDelay(response.value(forHTTPHeaderField: "Retry-After"), now: now)
        let object = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any]
        let error = object?["error"] as? [String: Any]
        let code = (error?["code"] as? String ?? error?["type"] as? String ?? "").lowercased()
        let message = (error?["message"] as? String ?? "").lowercased()
        switch statusCode {
        case 401: reason = .unauthorized
        case 403: reason = .forbidden
        case 429:
            if ["insufficient_quota", "quota_exceeded", "usage_limit_reached"].contains(code) { reason = .quota }
            else if ["overloaded", "overloaded_error", "server_overloaded"].contains(code) || message.contains("[overloaded]") || message.contains("the server is overloaded") { reason = .overloaded }
            else { reason = .rateLimited }
        case 500...599: reason = .unavailable
        default: reason = .request
        }
    }
    var errorDescription: String? {
        let detail: String
        switch reason {
        case .overloaded: detail = "模型服务暂时过载"
        case .rateLimited: detail = "模型服务暂时繁忙或限制了请求频率"
        case .quota: detail = "模型服务返回使用额度限制，请检查此订阅的额度"
        case .unauthorized: detail = "模型服务未通过授权，请检查密钥或登录状态"
        case .forbidden: detail = "模型服务拒绝访问，请检查服务权限及模型是否可用"
        case .unavailable: detail = "模型服务暂时不可用"
        case .request: detail = "模型请求被服务拒绝，请核对服务地址、模型与请求配置"
        }
        let retry = [.overloaded, .rateLimited, .unavailable].contains(reason) ? retryAfterSeconds.map { "请约 \($0) 秒后重试；" } ?? "请稍后重试；" : ""
        return "\(detail)（HTTP \(statusCode)）。\(retry)已保存内容保留。"
    }
    private static func retryDelay(_ value: String?, now: Date) -> Int? {
        guard let value, value.utf8.count <= 64 else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespaces)
        if let seconds = Int(trimmed), (1...3600).contains(seconds) { return seconds }
        let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0); formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss 'GMT'"
        formatter.isLenient = false
        guard let date = formatter.date(from: trimmed) else { return nil }
        let seconds = date.timeIntervalSince(now).rounded(.up)
        return (1...3600).contains(seconds) ? Int(seconds) : nil
    }
}
