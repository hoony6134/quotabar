import SwiftUI

/// Mac 데이터가 아직 없을 때의 첫 화면 — 설정 방법과 데모 체험을 안내한다.
struct OnboardingView: View {
    @EnvironmentObject var model: MirrorModel

    var body: some View {
        ScrollView {
            VStack(spacing: 24) {
                VStack(spacing: 12) {
                    QuotaRing(percent: 68, lineWidth: 12) {
                        Image(systemName: "gauge.with.dots.needle.67percent")
                            .font(.system(size: 34, weight: .semibold))
                            .foregroundStyle(.secondary)
                    }
                    .frame(width: 112, height: 112)
                    Text("AI 사용량을 한눈에")
                        .font(.title2.bold())
                    Text("Mac의 QuotaBar가 조회한 Claude·ChatGPT·Cursor·Copilot·Gemini 사용률을 iPhone 위젯과 앱에서 확인하세요.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .padding(.top, 24)

                VStack(alignment: .leading, spacing: 16) {
                    step(1, "Mac에서 QuotaBar 2.0 실행", "메뉴막대에 QuotaBar가 떠 있어야 합니다.")
                    step(2, "설정 → iPhone → 미러링 켜기", "기본으로 켜져 있어요.")
                    step(3, "같은 Apple ID로 iCloud 로그인", "iPhone과 Mac 모두 iCloud Drive가 켜져 있어야 합니다.")
                    step(4, "홈·잠금 화면에 위젯 추가", "홈 화면을 길게 눌러 + → QuotaBar")
                }
                .padding(18)
                .glassCard(cornerRadius: 22)

                VStack(spacing: 10) {
                    Button {
                        model.demoMode = true
                    } label: {
                        Label("데모 데이터로 둘러보기", systemImage: "play.circle.fill")
                            .font(.headline)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 6)
                    }
                    .buttonStyle(.borderedProminent)

                    Button {
                        model.reload()
                    } label: {
                        Label("다시 확인", systemImage: "arrow.clockwise")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                }
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 32)
        }
        .refreshable { model.reload() }
    }

    private func step(_ number: Int, _ title: String, _ detail: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text("\(number)")
                .font(.system(.footnote, design: .rounded).bold())
                .frame(width: 24, height: 24)
                .background(Color.primary.opacity(0.12), in: Circle())
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.subheadline.weight(.semibold))
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

struct SettingsView: View {
    @EnvironmentObject var model: MirrorModel
    @Environment(\.dismiss) private var dismiss

    private var version: String {
        let v = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "2.0"
        let b = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "1"
        return "\(v) (\(b))"
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Toggle("데모 데이터 보기", isOn: $model.demoMode)
                } footer: {
                    Text("Mac 없이 앱과 위젯의 모습을 미리 볼 수 있습니다.")
                }

                Section {
                    Toggle("리셋 알림", isOn: $model.resetNotifications)
                } footer: {
                    Text("쿼터가 초기화되는 시각에 알려 줍니다. Apple Watch로도 전달됩니다.")
                }

                if let snapshot = model.snapshot, snapshot.isDemo != true {
                    Section("연결된 Mac") {
                        LabeledContent("기기", value: snapshot.deviceName ?? "Mac")
                        LabeledContent("마지막 갱신", value: snapshot.generatedAt.formatted(date: .abbreviated, time: .shortened))
                        LabeledContent("쿼터", value: "\(snapshot.items.count)개")
                    }
                }

                Section("개인정보") {
                    Label("계정 비밀번호·토큰·쿠키는 iPhone으로 전송되지 않습니다.", systemImage: "lock.shield")
                    Label("사용률(%)과 리셋 시각만 내 iCloud를 통해 Mac에서 iPhone으로 전달됩니다.", systemImage: "icloud")
                    Label("분석·광고·추적 SDK를 사용하지 않습니다.", systemImage: "eye.slash")
                    if let url = URL(string: "https://github.com/hoony6134/quotabar/blob/main/docs/PRIVACY.md") {
                        Link(destination: url) {
                            Label("개인정보 처리방침", systemImage: "doc.text")
                        }
                    }
                }

                Section("정보") {
                    LabeledContent("버전", value: version)
                    if let url = URL(string: "https://github.com/hoony6134/quotabar") {
                        Link(destination: url) {
                            Label("Mac 앱 받기 · 지원", systemImage: "arrow.up.right.square")
                        }
                    }
                }
            }
            .navigationTitle("설정")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("완료") { dismiss() }
                }
            }
        }
    }
}
