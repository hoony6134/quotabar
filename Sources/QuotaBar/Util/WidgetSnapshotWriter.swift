import Foundation
import WidgetKit

/// 계정 상태를 App Group 컨테이너에 기록하고 위젯 타임라인을 갱신한다.
/// (앱 타깃 전용 — Account 타입에 의존하므로 위젯 타깃에는 포함하지 않는다)
enum WidgetSnapshotWriter {
    /// iPhone 미러링(iCloud) 사용 여부 — 설정에서 끌 수 있다.
    static let syncToiPhoneKey = "syncToiPhone"
    static var syncToiPhoneEnabled: Bool {
        UserDefaults.standard.object(forKey: syncToiPhoneKey) as? Bool ?? true
    }

    static func makeSnapshot(accounts: [Account], lastRefreshAt: Date?, nextRefreshAt: Date?) -> WidgetSnapshot {
        var items: [WidgetQuotaItem] = []
        for account in accounts {
            for quota in account.quotas {
                items.append(WidgetQuotaItem(
                    id: "\(account.id.uuidString)::\(quota.def.key)",
                    service: account.service.displayName,
                    label: account.label,
                    name: quota.def.name,
                    percent: (quota.utilization * 100).rounded(),
                    resetsAt: quota.resetsAt,
                    periodLabel: quota.def.period.label,
                    serviceID: account.service.rawValue,
                    colorHex: account.service.brandHex,
                    usageText: Fmt.usageLine(quota),
                    planName: account.detectedPlanName,
                    syncError: account.lastSyncError))
            }
        }
        items.sort { $0.percent > $1.percent }
        return WidgetSnapshot(generatedAt: Date(),
                              lastRefreshAt: lastRefreshAt,
                              nextRefreshAt: nextRefreshAt,
                              items: items,
                              deviceName: Host.current().localizedName)
    }

    static func write(accounts: [Account], lastRefreshAt: Date?, nextRefreshAt: Date?,
                      forceCloud: Bool = false) {
        let snapshot = makeSnapshot(accounts: accounts,
                                    lastRefreshAt: lastRefreshAt,
                                    nextRefreshAt: nextRefreshAt)
        let items = snapshot.items
        guard let data = snapshot.encoded() else { return }
        var attempts: [WidgetSnapshotWriteAttempt] = []
        for url in QuotaWidgetShared.snapshotFileURLs {
            do {
                try FileManager.default.createDirectory(
                    at: url.deletingLastPathComponent(),
                    withIntermediateDirectories: true)
                try data.write(to: url, options: .atomic)
                attempts.append(WidgetSnapshotWriteAttempt(path: url.path, ok: true, error: nil))
            } catch {
                attempts.append(WidgetSnapshotWriteAttempt(path: url.path,
                                                          ok: false,
                                                          error: error.localizedDescription))
            }
        }
        writeDebugStatus(generatedAt: snapshot.generatedAt,
                         itemCount: items.count,
                         attempts: attempts)

        // iPhone 미러링 — 표시용 데이터(%, 리셋 시각)만 올라가며 토큰은 포함되지 않는다.
        if syncToiPhoneEnabled, !items.isEmpty {
            QuotaCloudSync.writeSnapshot(snapshot, force: forceCloud)
        }

        WidgetCenter.shared.reloadAllTimelines()
    }

    private static func writeDebugStatus(generatedAt: Date,
                                         itemCount: Int,
                                         attempts: [WidgetSnapshotWriteAttempt]) {
        let status = WidgetSnapshotWriteStatus(generatedAt: generatedAt,
                                               itemCount: itemCount,
                                               attempts: attempts)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(status) else { return }
        let dir = FileManager.default.urls(for: .applicationSupportDirectory,
                                           in: .userDomainMask)[0]
            .appendingPathComponent("QuotaBar", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try? data.write(to: dir.appendingPathComponent("widget-write-status.json"),
                        options: .atomic)
    }
}

private struct WidgetSnapshotWriteStatus: Codable {
    var generatedAt: Date
    var itemCount: Int
    var attempts: [WidgetSnapshotWriteAttempt]
}

private struct WidgetSnapshotWriteAttempt: Codable {
    var path: String
    var ok: Bool
    var error: String?
}
