import Foundation
import Security

/// 앱 ↔ 위젯이 공유하는 스냅샷 모델.
/// 이 파일은 앱 타깃과 위젯 익스텐션 타깃 양쪽에 포함된다 (project.yml 참고).
enum QuotaWidgetShared {
    /// App Group ID — 자기 서명의 entitlement에서 런타임에 읽는다.
    /// macOS는 "<팀ID>.com.wevoid.quotabar" 형식만 동의 창 없이 검증되므로
    /// entitlement에 있는 그룹만 시도한다. (group.* 형식은 macOS 15+에서 권한 오류 유발)
    static let candidateAppGroupIDs: [String] = {
        var ids: [String] = []
        if let task = SecTaskCreateFromSelf(nil),
           let value = SecTaskCopyValueForEntitlement(
               task, "com.apple.security.application-groups" as CFString, nil),
           let groups = value as? [String] {
            ids.append(contentsOf: groups.filter { !$0.isEmpty })
        }
        if ids.isEmpty {
            // entitlement 없는 빌드(SPM build-app.sh)용 폴백 — Xcode 빌드와 같은 컨테이너
            ids = ["2S9H42VJUA.com.wevoid.quotabar"]
        }
        return Array(NSOrderedSet(array: ids)) as? [String] ?? ids
    }()

    static var appGroupID: String {
        candidateAppGroupIDs.first ?? "2S9H42VJUA.com.wevoid.quotabar"
    }

    static var snapshotFileURL: URL? {
        snapshotFileURLs.first
    }

    static var snapshotFileURLs: [URL] {
        let fileManager = FileManager.default
        var urls: [URL] = []
        for id in candidateAppGroupIDs {
            if let url = fileManager
                .containerURL(forSecurityApplicationGroupIdentifier: id)?
                .appendingPathComponent("widget-snapshot.json") {
                urls.append(url)
            }
        }
        let uniquePaths = NSOrderedSet(array: urls.map(\.path)).compactMap { $0 as? String }
        return uniquePaths.map { URL(fileURLWithPath: $0) }
    }

    /// 위젯 → 앱 새로고침 요청에 쓰는 분산 알림 이름
    static let refreshNotificationName = "com.wevoid.quotabar.refresh"
}

struct WidgetQuotaItem: Codable, Identifiable, Hashable {
    var id: String          // "<accountID>::<quotaKey>"
    var service: String     // 표시명 (예: "Claude")
    var label: String       // 계정 라벨 (예: "기본", "회사")
    var name: String        // 쿼터 이름 (예: "세션 (5시간)")
    var percent: Double     // 사용률 0...100
    var resetsAt: Date?
    var periodLabel: String?
    /// ServiceKind.rawValue — 위젯에서 로고 PNG 파일명으로 사용 (구버전 스냅샷 호환을 위해 옵셔널)
    var serviceID: String?
    /// 브랜드 색 hex (예: "D97857")
    var colorHex: String?
}

struct WidgetSnapshot: Codable {
    var generatedAt: Date
    var lastRefreshAt: Date?
    var nextRefreshAt: Date?
    /// 사용률 높은 순으로 정렬된 전체 쿼터 목록
    var items: [WidgetQuotaItem]

    static func load() -> WidgetSnapshot? {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        for url in QuotaWidgetShared.snapshotFileURLs {
            if let data = try? Data(contentsOf: url),
               let snapshot = try? decoder.decode(WidgetSnapshot.self, from: data) {
                return snapshot
            }
        }
        return nil
    }

    static let sample = WidgetSnapshot(
        generatedAt: Date(),
        lastRefreshAt: Date().addingTimeInterval(-4 * 60),
        nextRefreshAt: Date().addingTimeInterval(60),
        items: [
            WidgetQuotaItem(id: "1", service: "Claude", label: "기본",
                            name: "세션 (5시간)", percent: 62,
                            resetsAt: Date().addingTimeInterval(2 * 3600),
                            periodLabel: "5시간",
                            serviceID: "claude", colorHex: "D97857"),
            WidgetQuotaItem(id: "2", service: "Claude", label: "기본",
                            name: "주간 (전체 모델)", percent: 34,
                            resetsAt: Date().addingTimeInterval(3 * 86400),
                            periodLabel: "주간",
                            serviceID: "claude", colorHex: "D97857"),
            WidgetQuotaItem(id: "3", service: "ChatGPT", label: "기본",
                            name: "Codex 세션 (5시간)", percent: 18,
                            resetsAt: Date().addingTimeInterval(4 * 3600),
                            periodLabel: "5시간",
                            serviceID: "chatgpt", colorHex: "1AA68C"),
            WidgetQuotaItem(id: "4", service: "Copilot", label: "기본",
                            name: "프리미엄 요청", percent: 47,
                            resetsAt: Date().addingTimeInterval(12 * 86400),
                            periodLabel: "월간",
                            serviceID: "copilot", colorHex: "738CA6"),
        ])
}
