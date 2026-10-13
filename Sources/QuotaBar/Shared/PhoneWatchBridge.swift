#if os(iOS) || os(watchOS)
import Foundation
import WatchConnectivity

/// iPhone → Apple Watch 직접 전달 채널 (WatchConnectivity).
///
/// iCloud(KVS)는 기기마다 따로 당겨와야 하고 도착 시점을 보장하지 않아서, 워치가 "1시간 전" 같은
/// 낡은 값을 보여주는 일이 잦았다. iPhone은 새 스냅샷을 받는 즉시 이 채널로 워치에 밀어 넣고,
/// 워치는 iCloud보다 먼저(또는 iCloud 없이) 최신 값을 받는다. 토큰은 포함되지 않는다 — 표시용 데이터뿐.
///
/// - iPhone: `push(_:)` — applicationContext(최신 1건만 유지, 워치 앱이 꺼져 있어도 전달) +
///   워치가 가까이 켜져 있으면 sendMessage로 즉시 전달
/// - Watch: `onSnapshot`으로 수신
final class PhoneWatchBridge: NSObject, WCSessionDelegate, @unchecked Sendable {
    static let shared = PhoneWatchBridge()
    private static let payloadKey = "snapshot"

    /// 워치에서 새 스냅샷이 도착했을 때 호출된다 (임의 스레드).
    var onSnapshot: (@Sendable (WidgetSnapshot) -> Void)?

    private let lock = NSLock()
    private var pending: WidgetSnapshot?
    private var lastPushedAt: Date = .distantPast

    private override init() { super.init() }

    /// 앱 시작 시 한 번 호출한다. 이후 델리게이트 콜백이 오도록 세션을 활성화한다.
    func activate() {
        guard WCSession.isSupported() else { return }
        let session = WCSession.default
        session.delegate = self
        if session.activationState != .activated { session.activate() }
    }

    #if os(iOS)
    /// 워치로 스냅샷을 보낸다. 이미 보낸 것보다 오래됐거나 같으면 건너뛴다.
    func push(_ snapshot: WidgetSnapshot) {
        lock.lock()
        guard snapshot.generatedAt > lastPushedAt else { lock.unlock(); return }
        pending = snapshot
        lock.unlock()
        flush()
    }

    private func flush() {
        guard WCSession.isSupported() else { return }
        let session = WCSession.default
        guard session.activationState == .activated,
              session.isPaired, session.isWatchAppInstalled else { return }
        lock.lock()
        let snapshot = pending
        lock.unlock()
        guard let snapshot, let data = snapshot.encoded() else { return }
        let payload: [String: Any] = [Self.payloadKey: data]
        do {
            try session.updateApplicationContext(payload)
        } catch {
            return
        }
        if session.isReachable {
            session.sendMessage(payload, replyHandler: nil, errorHandler: nil)
        }
        lock.lock()
        lastPushedAt = snapshot.generatedAt
        pending = nil
        lock.unlock()
    }
    #endif

    // MARK: WCSessionDelegate

    func session(_ session: WCSession,
                 activationDidCompleteWith activationState: WCSessionActivationState,
                 error: Error?) {
        #if os(iOS)
        if activationState == .activated { flush() }
        #endif
    }

    #if os(iOS)
    func sessionDidBecomeInactive(_ session: WCSession) {}

    func sessionDidDeactivate(_ session: WCSession) {
        // 워치를 바꿔 페어링한 경우 새 세션을 다시 활성화해야 한다.
        session.activate()
    }

    func sessionWatchStateDidChange(_ session: WCSession) {
        // 워치 앱이 막 설치됐거나 페어링이 바뀌었다 — 마지막 값을 다시 보낸다.
        lock.lock()
        lastPushedAt = .distantPast
        lock.unlock()
        flush()
    }
    #endif

    func session(_ session: WCSession, didReceiveApplicationContext applicationContext: [String: Any]) {
        receive(applicationContext)
    }

    func session(_ session: WCSession, didReceiveMessage message: [String: Any]) {
        receive(message)
    }

    private func receive(_ dict: [String: Any]) {
        guard let data = dict[Self.payloadKey] as? Data,
              let snapshot = WidgetSnapshot.decode(data) else { return }
        onSnapshot?(snapshot)
    }
}
#endif
