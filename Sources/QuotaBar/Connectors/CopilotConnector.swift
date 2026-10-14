import Foundation

/// GitHub Copilot — 에디터 클라이언트가 쓰는 내부 엔드포인트에서
/// 프리미엄 요청/채팅/자동완성 쿼터 스냅샷을 가져온다. 비공식 엔드포인트.
///
/// 인증:
/// - `auto:copilot` 센티널 — 에디터(VS Code/JetBrains/Neovim 등)가 저장한 Copilot OAuth 토큰
///   (`~/.config/github-copilot/apps.json`·`hosts.json`)을 읽고, 없으면 `gh auth token`을 쓴다.
/// - 직접 붙여넣은 GitHub 토큰.
struct CopilotConnector: QuotaConnector {
    static let autoSentinel = "auto:copilot"
    private static let url = URL(string: "https://api.github.com/copilot_internal/user")!

    func fetch(credential: String, context: ConnectorContext?) async throws -> [QuotaUpdate] {
        var token = credential
        if credential == Self.autoSentinel {
            guard let detected = Self.detectToken() else {
                throw ConnectorError.hint("Copilot 로그인 정보를 찾지 못했습니다. VS Code에서 Copilot에 로그인하거나 `gh auth login` 후 다시 시도하세요. (또는 GitHub 토큰을 직접 붙여넣을 수 있습니다)")
            }
            token = detected
        }
        let (data, code) = try await HTTP.get(Self.url, headers: [
            // 에디터 플러그인과 같은 `token` 스킴 (classic PAT/OAuth 모두 허용)
            "Authorization": "token \(token)",
            "Accept": "application/json",
            "Editor-Version": "vscode/1.96.2",
            "Editor-Plugin-Version": "copilot-chat/0.26.7",
            "User-Agent": "GitHubCopilotChat/0.26.7",
            "X-Github-Api-Version": "2025-04-01",
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
                var used = max(entitlement - remaining, 0)
                // 개수 없이 남은 비율만 내려오는 응답(percent_remaining) 대응
                if entitlement <= 0, let pct = (snap["percent_remaining"] as? NSNumber)?.doubleValue {
                    updates.append(QuotaUpdate(key: kind.key, name: kind.name,
                                               used: max(100 - pct, 0), cap: 100, unit: "%",
                                               resetsAt: resetDate,
                                               planName: Self.plan(from: json)))
                    continue
                }
                if entitlement > 0, remaining > entitlement { used = 0 }
                updates.append(QuotaUpdate(key: kind.key, name: kind.name,
                                           used: used,
                                           cap: entitlement > 0 ? entitlement : nil,
                                           unit: "회", resetsAt: resetDate,
                                           planName: Self.plan(from: json)))
            }
        }

        guard !updates.isEmpty else {
            throw ConnectorError.schemaChanged("quota_snapshots 필드 없음")
        }
        return updates
    }

    /// `copilot_plan`(individual/business/enterprise/free…) 우선, 없으면 일반 탐색
    private static func plan(from json: [String: Any]) -> String? {
        if let raw = (json["copilot_plan"] as? String) ?? (json["access_type_sku"] as? String) {
            let lower = raw.lowercased()
            if lower.contains("edu") || lower.contains("student") { return "Edu" }
            if lower.contains("enterprise") { return "Enterprise" }
            if lower.contains("business") { return "Business" }
            if lower.contains("pro_plus") || lower.contains("pro+") { return "Pro+" }
            if lower.contains("free") { return "Free" }
            if lower.contains("individual") || lower.contains("pro") { return "Pro" }
        }
        return PlanDetection.from(json: json)
    }

    // MARK: - 토큰 자동 감지

    static func detectToken() -> String? {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let dirs = [home.appendingPathComponent(".config/github-copilot"),
                    home.appendingPathComponent("Library/Application Support/github-copilot")]
        for dir in dirs {
            for name in ["apps.json", "hosts.json"] {
                guard let data = try? Data(contentsOf: dir.appendingPathComponent(name)),
                      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
                // {"github.com:Iv1.xxxx": {"oauth_token": "gho_..."}} 형태
                for (host, value) in json where host.hasPrefix("github.com") {
                    if let entry = value as? [String: Any],
                       let token = entry["oauth_token"] as? String, !token.isEmpty { return token }
                }
            }
        }
        return ghAuthToken()
    }

    private static func ghAuthToken() -> String? {
        let candidates = ["/opt/homebrew/bin/gh", "/usr/local/bin/gh", "/usr/bin/gh"]
        guard let bin = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else { return nil }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: bin)
        process.arguments = ["auth", "token"]
        let out = Pipe()
        process.standardOutput = out
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return nil }
        process.waitUntilExit()
        guard process.terminationStatus == 0,
              let text = String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
              !text.isEmpty else { return nil }
        return text
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
