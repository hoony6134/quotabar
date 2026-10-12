import SwiftUI

/// 전역 설정 (⌘,)
struct AppSettingsView: View {
    @EnvironmentObject var store: AppStore

    var body: some View {
        Form {
            Section("동기화") {
                Picker("자동 새로고침 주기", selection: $store.refreshIntervalMinutes) {
                    Text("1분").tag(1)
                    Text("5분").tag(5)
                    Text("10분").tag(10)
                    Text("30분").tag(30)
                }
            }
            Section("iPhone") {
                Toggle("iPhone 앱·위젯으로 미러링 (iCloud)", isOn: $store.syncToiPhone)
                Text("사용률(%)과 리셋 시각만 내 iCloud 계정으로 동기화됩니다. 토큰·쿠키 등 자격증명은 Mac 밖으로 나가지 않습니다. iPhone에서 같은 Apple ID로 QuotaBar를 열면 위젯과 앱에 표시됩니다.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("표시") {
                Toggle("Dock 아이콘 숨기기 (메뉴막대 전용)", isOn: $store.hideDockIcon)
                Picker("메뉴막대 퍼센트", selection: $store.menuBarQuotaSelection) {
                    ForEach(store.menuBarQuotaOptions) { option in
                        Text("\(option.title) · \(option.percentage)%").tag(option.id)
                    }
                }
            }
            Section("알림") {
                Toggle("세션 초기화 시 알림 받기", isOn: $store.enableResetNotifications)
            }
            Section("정보") {
                LabeledContent("버전", value: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "2.0")
            }
            Section {
                Text("Claude·Codex·Cursor·Copilot은 비공식 사용량 엔드포인트를 사용합니다. Gemini·Antigravity는 공개 잔량 API가 없어 로컬 기록 기반 활동량으로 자동 추정합니다.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 460)
    }
}
