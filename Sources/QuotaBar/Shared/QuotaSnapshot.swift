import Foundation
#if os(macOS)
import Security
#endif

/// 앱 ↔ 위젯 ↔ iPhone 이 공유하는 스냅샷 모델과 저장 위치.
/// 이 파일은 macOS 앱 / macOS 위젯 / iOS 앱 / iOS 위젯 네 타깃에 모두 포함된다 (project.yml 참고).
enum QuotaWidgetShared {
    /// App Group ID 후보.
    /// - macOS: "<팀ID>.com.wevoid.quotabar" 형식만 동의 창 없이 검증되므로 entitlement에 있는
    ///   그룹만 시도한다. (group.* 형식은 macOS 15+에서 권한 오류 유발)
    /// - iOS: 표준 "group.com.wevoid.quotabar"
    static let candidateAppGroupIDs: [String] = {
        #if os(macOS)
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
        #else
        return ["group.com.wevoid.quotabar"]
        #endif
    }()

    static var appGroupID: String {
        candidateAppGroupIDs.first ?? "group.com.wevoid.quotabar"
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

    /// 위젯 → 앱 새로고침 요청에 쓰는 분산 알림 이름 (macOS 전용)
    static let refreshNotificationName = "com.wevoid.quotabar.refresh"

    /// iCloud 키-값 저장소 키. Mac이 쓰고 iPhone이 읽는다.
    static let kvsSnapshotKey = "quotabar.snapshot.v2"
    /// iPhone → Mac 새로고침 요청 (타임스탬프). Mac이 감시한다.
    static let kvsRefreshRequestKey = "quotabar.refreshRequest.v2"
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
    // ---- v2 추가 필드 (모두 옵셔널 — 구버전 스냅샷과 호환) ----
    /// "142 / 300회" 같은 사용량 문자열
    var usageText: String?
    /// 감지된 플랜 이름 (예: "Max")
    var planName: String?
    /// 마지막 동기화 오류 메시지 (있으면 값이 오래됐을 수 있음)
    var syncError: String?
}

struct WidgetSnapshot: Codable {
    var generatedAt: Date
    var lastRefreshAt: Date?
    var nextRefreshAt: Date?
    /// 사용률 높은 순으로 정렬된 전체 쿼터 목록
    var items: [WidgetQuotaItem]
    // ---- v2 ----
    var schemaVersion: Int? = 2
    /// 스냅샷을 만든 기기 이름 (예: "훈의 MacBook Pro")
    var deviceName: String?
    /// true면 App Review/체험용 데모 데이터
    var isDemo: Bool? = nil

    static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        return e
    }()

    static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    func encoded() -> Data? { try? Self.encoder.encode(self) }

    static func decode(_ data: Data) -> WidgetSnapshot? {
        try? decoder.decode(WidgetSnapshot.self, from: data)
    }

    /// 앱 그룹 파일에서 읽는다.
    static func loadFromGroupFile() -> WidgetSnapshot? {
        var best: WidgetSnapshot?
        for url in QuotaWidgetShared.snapshotFileURLs {
            if let data = try? Data(contentsOf: url),
               let snapshot = decode(data),
               snapshot.generatedAt > (best?.generatedAt ?? .distantPast) {
                best = snapshot
            }
        }
        return best
    }

    /// 앱 그룹 파일에 쓴다. 성공한 경로 수를 돌려준다.
    @discardableResult
    func writeToGroupFiles() -> Int {
        guard let data = encoded() else { return 0 }
        var ok = 0
        for url in QuotaWidgetShared.snapshotFileURLs {
            do {
                try FileManager.default.createDirectory(
                    at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try data.write(to: url, options: .atomic)
                ok += 1
            } catch {}
        }
        return ok
    }

    /// 위젯/앱이 쓰는 통합 로더: 앱 그룹 파일과 iCloud KVS 중 더 최신 것을 쓴다.
    /// (macOS 위젯은 KVS entitlement가 없으므로 파일만 본다.)
    static func load() -> WidgetSnapshot? {
        let file = loadFromGroupFile()
        #if os(iOS)
        let cloud = QuotaCloudSync.readSnapshot()
        if let cloud, cloud.generatedAt > (file?.generatedAt ?? .distantPast) { return cloud }
        #endif
        return file
    }

    var worstPercent: Double { items.map(\.percent).max() ?? 0 }

    static let sample = WidgetSnapshot(
        generatedAt: Date(),
        lastRefreshAt: Date().addingTimeInterval(-4 * 60),
        nextRefreshAt: Date().addingTimeInterval(60),
        items: makeSampleItems(now: Date()),
        deviceName: "MacBook Pro",
        isDemo: true)

    /// App Review / 첫 체험용 데모 데이터 (Mac이 없는 심사자도 모든 화면을 볼 수 있어야 한다)
    static func demo(now: Date = Date()) -> WidgetSnapshot {
        WidgetSnapshot(generatedAt: now, lastRefreshAt: now, nextRefreshAt: now.addingTimeInterval(300),
                       items: makeSampleItems(now: now), deviceName: "MacBook Pro", isDemo: true)
    }

    private static func makeSampleItems(now: Date) -> [WidgetQuotaItem] {
        func item(_ id: String, _ svc: String, _ sid: String, _ hex: String, _ name: String,
                  _ pct: Double, _ period: String, _ reset: TimeInterval,
                  plan: String? = nil, usage: String? = nil) -> WidgetQuotaItem {
            WidgetQuotaItem(id: id, service: svc, label: "기본", name: name, percent: pct,
                            resetsAt: now.addingTimeInterval(reset), periodLabel: period,
                            serviceID: sid, colorHex: hex, usageText: usage ?? "\(Int(pct))%",
                            planName: plan, syncError: nil)
        }
        return [
            item("d1", "Claude", "claude", "D97857", "세션 (5시간)", 91, "5시간", 1.4 * 3600, plan: "Max"),
            item("d2", "Claude", "claude", "D97857", "주간 (전체 모델)", 58, "주간", 3 * 86400, plan: "Max"),
            item("d3", "ChatGPT", "chatgpt", "1AA68C", "Codex 세션 (5시간)", 64, "5시간", 3.2 * 3600, plan: "Plus"),
            item("d4", "ChatGPT", "chatgpt", "1AA68C", "Codex 주간", 27, "주간", 5 * 86400, plan: "Plus"),
            item("d5", "Cursor", "cursor", "7366F2", "포함 사용량", 41, "월간", 12 * 86400, plan: "Pro", usage: "$8.20 / $20"),
            item("d6", "GitHub Copilot", "copilot", "738CA6", "프리미엄 요청", 47, "월간", 12 * 86400, plan: "Edu", usage: "141 / 300회"),
            item("d7", "Gemini", "googleAI", "4285F5", "Gemini 활동 (오늘)", 22, "일간", 7 * 3600, plan: "AI Pro", usage: "22 / 100회"),
        ].sorted { $0.percent > $1.percent }
    }
}
