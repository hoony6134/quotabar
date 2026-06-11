import Foundation

/// GitHub Copilot — 에디터 클라이언트가 쓰는 내부 엔드포인트에서
/// 프리미엄 요청/채팅/자동완성 쿼터 스냅샷을 가져온다. 비공식 엔드포인트.
struct CopilotConnector: QuotaConnector {
    private static let url = URL(string: "https://api.github.com/copilot_internal/user")!

    func fetch(credential: String) async throws -> [QuotaUpdate] {
        let (data, code) = try await HTTP.get(Self.url, headers: [
            "Authorization": "Bearer \(credential)",
            "Accept": "application/json",
            "Editor-Version": "vscode/1.100.0",
            "User-Agent": "GitHubCopilotChat/0.26.0",
        ])

        switch code {
        case 200: break
        case 401, 403: throw ConnectorError.unauthorized
        case 429: throw ConnectorError.rateLimited
        default: throw ConnectorError.network("HTTP \(code)")
        }

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ConnectorError.schemaChanged("JSON 아님")
        }

        let resetDate = parseResetDate(json["quota_reset_date"] as? String)
        var updates: [QuotaUpdate] = []

        if let snapshots = json["quota_snapshots"] as? [String: Any] {
            let kinds: [(key: String, snapshotKey: String, name: String)] = [
                ("premium_requests", "premium_interactions", "프리미엄 요청"),
                ("chat", "chat", "채팅"),
                ("completions", "completions", "자동완성"),
            ]
            for kind in kinds {
                guard let snap = snapshots[kind.snapshotKey] as? [String: Any] else { continue }
                let unlimited = (snap["unlimited"] as? Bool) ?? false
                if unlimited && kind.key != "premium_requests" { continue } // 무제한 항목은 생략
                let entitlement = (snap["entitlement"] as? NSNumber)?.doubleValue ?? 0
                let remaining = (snap["remaining"] as? NSNumber)?.doubleValue
                    ?? (snap["quota_remaining"] as? NSNumber)?.doubleValue ?? entitlement
                let used = max(entitlement - remaining, 0)
                updates.append(QuotaUpdate(key: kind.key, name: kind.name,
                                           used: used,
                                           cap: entitlement > 0 ? entitlement : nil,
                                           unit: "회", resetsAt: resetDate,
                                           planName: PlanDetection.from(json: json)))
            }
        }

        guard !updates.isEmpty else {
            throw ConnectorError.schemaChanged("quota_snapshots 필드 없음")
        }
        return updates
    }

    /// quota_reset_date 는 "2026-07-01" 형태
    private func parseResetDate(_ string: String?) -> Date? {
        guard let string else { return nil }
        if let iso = DateParsing.iso8601(string) { return iso }
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.timeZone = TimeZone(identifier: "UTC")
        return formatter.date(from: string)
    }
}
