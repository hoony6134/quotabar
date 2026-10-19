import Foundation
import AppKit

/// GitHub Releases 의 최신 버전을 확인해 새 버전이 있으면 알려준다.
@MainActor
final class UpdateChecker: ObservableObject {
    static let shared = UpdateChecker()

    enum State: Equatable {
        case idle
        case checking
        case upToDate
        case available(version: String, url: URL)
        case failed
    }

    @Published private(set) var state: State = .idle

    private let latestReleaseAPI = URL(string: "https://api.github.com/repos/hoony6134/quotabar/releases/latest")!
    private let lastCheckKey = "lastUpdateCheck"
    private let checkInterval: TimeInterval = 60 * 60 * 24

    static var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    }

    /// 실행 시 호출: 마지막 확인 후 하루가 지났을 때만 조용히 확인한다.
    func checkIfNeeded() {
        let last = UserDefaults.standard.object(forKey: lastCheckKey) as? Date
        guard last == nil || Date().timeIntervalSince(last!) > checkInterval else { return }
        Task { await check() }
    }

    func check() async {
        guard state != .checking else { return }
        state = .checking
        var request = URLRequest(url: latestReleaseAPI)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 15
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200,
                  let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let tag = json["tag_name"] as? String else {
                state = .failed
                return
            }
            UserDefaults.standard.set(Date(), forKey: lastCheckKey)
            let latest = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
            if Self.isNewer(latest, than: Self.currentVersion) {
                let page = (json["html_url"] as? String).flatMap(URL.init(string:))
                    ?? URL(string: "https://github.com/hoony6134/quotabar/releases/latest")!
                state = .available(version: latest, url: page)
            } else {
                state = .upToDate
            }
        } catch {
            state = .failed
        }
    }

    func openDownloadPage() {
        if case .available(_, let url) = state { NSWorkspace.shared.open(url) }
    }

    /// 점(.)으로 구분된 숫자 버전 비교 (2.1.10 > 2.1.9)
    static func isNewer(_ a: String, than b: String) -> Bool {
        let pa = a.split(separator: ".").map { Int($0) ?? 0 }
        let pb = b.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(pa.count, pb.count) {
            let x = i < pa.count ? pa[i] : 0
            let y = i < pb.count ? pb[i] : 0
            if x != y { return x > y }
        }
        return false
    }
}
