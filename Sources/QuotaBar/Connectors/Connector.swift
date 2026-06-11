import Foundation

/// 커넥터가 돌려주는 쿼터 갱신값. `key`로 계정의 QuotaItem과 매칭된다.
struct QuotaUpdate {
    var key: String
    var name: String?
    var used: Double
    var cap: Double?
    var unit: String?
    var resetsAt: Date?
    var planName: String? = nil
}

enum ConnectorError: LocalizedError {
    case noCredential
    case unauthorized
    case rateLimited
    case schemaChanged(String)
    case network(String)
    case hint(String)

    var errorDescription: String? {
        switch self {
        case .noCredential:         return "인증 정보가 없습니다. 계정 설정에서 토큰을 입력하세요."
        case .unauthorized:         return "인증 실패 (401/403). 토큰이 만료됐거나 잘못되었습니다."
        case .rateLimited:          return "요청이 제한되었습니다 (429). 잠시 후 다시 시도하세요."
        case .schemaChanged(let s): return "응답 형식을 해석하지 못했습니다: \(s). 서비스 API가 변경된 것 같습니다."
        case .network(let s):       return "네트워크 오류: \(s)"
        case .hint(let s):          return s
        }
    }
}

protocol QuotaConnector {
    /// 인증 토큰으로 서비스 사용량을 조회한다.
    func fetch(credential: String) async throws -> [QuotaUpdate]
}

// MARK: - 공용 HTTP / 날짜 유틸

enum HTTP {
    static func get(_ url: URL, headers: [String: String]) async throws -> (Data, Int) {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        headers.forEach { request.setValue($1, forHTTPHeaderField: $0) }
        return try await run(request)
    }

    static func post(_ url: URL, headers: [String: String], jsonBody: [String: Any]) async throws -> (Data, Int) {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        headers.forEach { request.setValue($1, forHTTPHeaderField: $0) }
        request.httpBody = try JSONSerialization.data(withJSONObject: jsonBody)
        return try await run(request)
    }

    private static func run(_ request: URLRequest) async throws -> (Data, Int) {
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            return (data, code)
        } catch {
            throw ConnectorError.network(error.localizedDescription)
        }
    }
}

enum DateParsing {
    /// ISO8601 (소수점 초 유무 모두) 파싱
    static func iso8601(_ string: String?) -> Date? {
        guard let string else { return nil }
        let withFraction = ISO8601DateFormatter()
        withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = withFraction.date(from: string) { return date }
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        return plain.date(from: string)
    }
}

enum PlanDetection {
    static func from(json: [String: Any]) -> String? {
        scan(json)
    }

    static func normalize(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let lower = trimmed.lowercased()
        if lower.contains("ultra") { return "Ultra" }
        if lower.contains("max") { return "Max" }
        if lower.contains("team") { return "Team" }
        if lower.contains("enterprise") || lower.contains("business") { return "Enterprise" }
        if lower.contains("pro") { return "Pro" }
        if lower.contains("plus") { return "Plus" }
        if lower.contains("edu") || lower.contains("student") { return "Edu" }
        if lower.contains("free") { return "Free" }
        return trimmed
    }

    private static func scan(_ value: Any) -> String? {
        if let dict = value as? [String: Any] {
            let priorityKeys = [
                "plan", "plan_name", "plan_type", "subscription_plan",
                "subscription_tier", "tier", "account_plan", "sku"
            ]
            for key in priorityKeys {
                if let found = normalize(dict[key] as? String) { return found }
            }
            for (key, value) in dict {
                let lower = key.lowercased()
                if lower.contains("plan") || lower.contains("tier") || lower.contains("subscription") {
                    if let found = normalize(value as? String) { return found }
                }
            }
            for value in dict.values {
                if let found = scan(value) { return found }
            }
        } else if let array = value as? [Any] {
            for value in array {
                if let found = scan(value) { return found }
            }
        }
        return nil
    }
}
