import Foundation

/// QuotaBar 상태를 Obsidian 볼트에 마크다운(+JSON)으로 내보낸다.
/// Cowork의 "Today Status" 아티팩트가 Obsidian MCP로 이 파일을 읽어 쿼터를 표시한다.
enum StatusExporter {

    /// 볼트 내 내보내기 경로 (아티팩트의 filepath와 일치해야 함)
    static let vaultRelativePath = "Utils/QuotaBar Status.md"

    /// 계정 상태를 내보낸다.
    /// - Parameter customPath: 비어있지 않으면 이 절대 경로 파일에 기록.
    ///   비어있으면 Obsidian 설정에서 열린 볼트를 자동 감지해 `Utils/QuotaBar Status.md`에 기록.
    static func export(accounts: [Account], customPath: String) {
        let url: URL
        if !customPath.isEmpty {
            url = URL(fileURLWithPath: (customPath as NSString).expandingTildeInPath)
        } else if let vault = detectVaultURL() {
            url = vault.appendingPathComponent(vaultRelativePath)
        } else {
            return // 내보낼 곳 없음 — 조용히 건너뜀
        }

        let iso = ISO8601DateFormatter()
        let now = iso.string(from: Date())

        var accountList: [[String: Any]] = []
        for account in accounts {
            var quotaList: [[String: Any]] = []
            for quota in account.quotas {
                var entry: [String: Any] = [
                    "key": quota.def.key,
                    "name": quota.def.name,
                    "used": round(quota.state.used * 100) / 100,
                    "cap": quota.def.cap,
                    "unit": quota.def.unit,
                    "period": quota.def.period.label,
                    "utilization": round(quota.utilization * 1000) / 1000,
                ]
                if let resetsAt = quota.resetsAt {
                    entry["resetsAt"] = iso.string(from: resetsAt)
                }
                quotaList.append(entry)
            }
            var entry: [String: Any] = [
                "service": account.service.displayName,
                "plan": account.detectedPlanName ?? account.service.planName,
                "label": account.label,
                "worstUtilization": round(account.worstUtilization * 1000) / 1000,
                "quotas": quotaList,
            ]
            if let error = account.lastSyncError {
                entry["syncError"] = error
            }
            if let at = account.lastSyncAt {
                entry["lastSyncAt"] = iso.string(from: at)
            }
            accountList.append(entry)
        }

        let payload: [String: Any] = [
            "generatedAt": now,
            "app": "QuotaBar",
            "accounts": accountList,
        ]

        guard let data = try? JSONSerialization.data(withJSONObject: payload,
                                                     options: [.prettyPrinted, .sortedKeys]),
              let json = String(data: data, encoding: .utf8) else { return }

        let markdown = """
        ---
        tags: [quotabar, auto-generated]
        updated: \(now)
        ---

        # QuotaBar 상태

        QuotaBar 앱이 자동 생성하는 파일입니다. 직접 수정하지 마세요.
        Cowork의 Today Status 아티팩트가 이 파일을 읽습니다.

        ```json
        \(json)
        ```
        """

        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true)
        try? markdown.data(using: .utf8)?.write(to: url, options: .atomic)
    }

    /// Obsidian 설정(~/Library/Application Support/obsidian/obsidian.json)에서
    /// 현재 열린(또는 가장 최근) 볼트 경로를 찾는다.
    static func detectVaultURL() -> URL? {
        let config = FileManager.default.urls(for: .applicationSupportDirectory,
                                              in: .userDomainMask)[0]
            .appendingPathComponent("obsidian/obsidian.json")
        guard let data = try? Data(contentsOf: config),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let vaults = json["vaults"] as? [String: [String: Any]], !vaults.isEmpty
        else { return nil }

        // open == true 인 볼트 우선, 없으면 ts(최근 사용)가 가장 큰 볼트
        let sorted = vaults.values.sorted { a, b in
            let openA = (a["open"] as? Bool) ?? false
            let openB = (b["open"] as? Bool) ?? false
            if openA != openB { return openA }
            let tsA = (a["ts"] as? NSNumber)?.doubleValue ?? 0
            let tsB = (b["ts"] as? NSNumber)?.doubleValue ?? 0
            return tsA > tsB
        }
        guard let path = sorted.first?["path"] as? String, !path.isEmpty else { return nil }
        return URL(fileURLWithPath: path, isDirectory: true)
    }
}
