import Foundation

/// Mac ↔ iPhone 미러링 채널 — iCloud 키-값 저장소(NSUbiquitousKeyValueStore).
///
/// - Mac 앱이 사용량을 조회해 스냅샷(JSON, 수 KB)을 쓴다.
/// - iPhone 앱/위젯은 같은 Apple ID의 iCloud를 통해 그것을 읽는다. 별도 서버·계정·토큰 전송이 없고,
///   **자격증명(토큰)은 절대 올라가지 않는다** — 사용률(%)과 리셋 시각 같은 표시용 데이터만 동기화된다.
/// - iPhone이 당겨서 새로고침하면 `requestRefresh()`로 Mac에 갱신을 요청한다.
///
/// 필요한 entitlement: `com.apple.developer.ubiquity-kvstore-identifier`
enum QuotaCloudSync {
    private static var store: NSUbiquitousKeyValueStore { .default }

    // MARK: 읽기

    static func readSnapshot() -> WidgetSnapshot? {
        guard let data = store.data(forKey: QuotaWidgetShared.kvsSnapshotKey) else { return nil }
        return WidgetSnapshot.decode(data)
    }

    static var refreshRequestDate: Date? {
        let t = store.double(forKey: QuotaWidgetShared.kvsRefreshRequestKey)
        return t > 0 ? Date(timeIntervalSince1970: t) : nil
    }

    // MARK: 쓰기

    private static var lastWrittenDigest: Data?
    private static var lastWrittenAt: Date?

    /// 내용이 바뀌었거나 2분 이상 지났을 때만 쓰고, 강제가 아니면 30초 이내 재기록은 건너뛴다
    /// (KVS는 쓰기 빈도 제한이 있고, 앱 상태 저장은 갱신 중 여러 번 일어난다).
    /// 값이 같아도 주기적으로 쓰는 이유: generatedAt이 "마지막으로 Mac이 살아 있던 시각"이라
    /// 기기들이 "n분 전"을 정확히 표시하려면 하트비트가 필요하다.
    /// - Returns: 실제로 썼는지
    @discardableResult
    static func writeSnapshot(_ snapshot: WidgetSnapshot, force: Bool = false) -> Bool {
        // generatedAt은 매번 달라지므로 비교에서 제외
        var comparable = snapshot
        comparable.generatedAt = .distantPast
        let digest = comparable.encoded()
        let since = lastWrittenAt.map { Date().timeIntervalSince($0) } ?? .infinity
        guard force || (since > 30 && (since > 120 || digest != lastWrittenDigest)) else { return false }
        guard let data = snapshot.encoded(), data.count < 900_000 else { return false }
        store.set(data, forKey: QuotaWidgetShared.kvsSnapshotKey)
        store.synchronize()
        lastWrittenDigest = digest
        lastWrittenAt = Date()
        return true
    }

    /// iPhone → Mac: 지금 갱신해 달라는 요청
    static func requestRefresh() {
        store.set(Date().timeIntervalSince1970, forKey: QuotaWidgetShared.kvsRefreshRequestKey)
        store.synchronize()
    }

    // MARK: 변경 감시

    static func synchronize() { store.synchronize() }

    /// iCloud에서 최신 값을 당겨오고, 더 새로운 스냅샷이 도착하면 바로 돌려준다.
    /// 백그라운드 갱신처럼 "외부 변경 알림"을 기다릴 수 없는 곳에서 쓴다.
    /// KVS 반영은 비동기라 `timeout`초 안에 새 값이 없으면 현재 값을 그대로 돌려준다.
    static func pull(timeout: TimeInterval = 4) async -> WidgetSnapshot? {
        let before = readSnapshot()?.generatedAt
        store.synchronize()
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            try? await Task.sleep(nanoseconds: 250_000_000)
            if let current = readSnapshot(), current.generatedAt != before { return current }
        }
        return readSnapshot()
    }

    /// 다른 기기에서 값이 바뀌면 호출된다. 반환된 토큰은 호출자가 보관한다.
    static func observeChanges(_ handler: @escaping @Sendable () -> Void) -> NSObjectProtocol {
        NotificationCenter.default.addObserver(
            forName: NSUbiquitousKeyValueStore.didChangeExternallyNotification,
            object: store, queue: .main) { _ in handler() }
    }
}
