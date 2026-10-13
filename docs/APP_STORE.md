# App Store 배포 가이드 (iOS · QuotaBar 2.0)

> macOS 앱은 `~/.claude`, `~/.codex`, 키체인 등을 읽어야 해서 **샌드박스를 켤 수 없으므로 Mac App Store 대신 Developer ID 직접 배포**를 유지합니다.
> App Store에는 **iOS 앱(QuotaBarMobile) + 위젯**을 올립니다. iOS 앱은 자격증명을 다루지 않고 Mac이 올린 표시용 데이터만 보여 줍니다.

## 1. 사전 준비
1. Apple Developer Program 가입, Team ID 확인.
2. `project.yml`의 번들 ID(`com.wevoid.*`)를 본인 것으로 바꾸고 `xcodegen generate`.
3. Developer 포털 → Identifiers:
   - `com.wevoid.quotabar.mobile`, `com.wevoid.quotabar.mobile.widget`
   - App Groups: `group.com.wevoid.quotabar`
   - iCloud: **Key-value storage** 활성화 (Mac 앱 `com.wevoid.quotabar` 포함 세 ID 모두 같은 KVS 컨테이너 `<TeamID>.com.wevoid.quotabar`)
4. Xcode에서 세 타깃 모두 Team 선택 → Signing & Capabilities에 App Groups · iCloud(Key-value storage)가 보이는지 확인.

## 2. 빌드·업로드
1. 스킴 `QuotaBarMobile` → Product ▸ Archive → Distribute App ▸ App Store Connect.
2. App Store Connect에서 TestFlight 내부 테스트 후 심사 제출.

## 3. 메타데이터 (복사해서 사용)
- **이름:** QuotaBar — AI 사용량 위젯
- **부제(30자):** Claude·ChatGPT·Cursor 한도 한눈에
- **카테고리:** 유틸리티 (보조: 개발자 도구)
- **연령 등급:** 4+
- **키워드:** claude,chatgpt,codex,cursor,copilot,gemini,quota,usage,widget,ai,limit,사용량,한도,위젯
- **지원 URL:** https://github.com/hoony6134/quotabar
- **개인정보 처리방침 URL:** https://github.com/hoony6134/quotabar/blob/main/docs/PRIVACY.md
- **프로모션 문구:** Mac의 QuotaBar가 조회한 AI 구독 사용률을 iPhone 홈·잠금 화면 위젯으로.
- **설명:**
  > QuotaBar는 Claude, ChatGPT(Codex), Cursor, GitHub Copilot, Gemini 등 AI 구독의 사용량 한도를 한눈에 보여 줍니다.
  > • 홈 화면·잠금 화면 위젯 (작게/중간/크게/원형/직사각형/인라인)
  > • 세션·주간·월간 한도와 리셋까지 남은 시간
  > • Mac의 QuotaBar와 iCloud로 자동 미러링 — 별도 계정·서버 없음
  > • 토큰·비밀번호는 iPhone으로 전송되지 않습니다
  > ※ 이 앱은 Mac용 QuotaBar와 함께 사용합니다. Mac 없이도 "데모 데이터"로 모든 화면을 둘러볼 수 있습니다.
- **개인정보 영양 라벨:** "데이터 수집 없음" (PrivacyInfo.xcprivacy 포함: UserDefaults CA92.1 / 파일 타임스탬프 C617.1)
- **수출 규정:** 표준 암호화만 사용(`ITSAppUsesNonExemptEncryption = false`)

## 4. App Review 메모 (심사자에게)
> This app mirrors usage percentages from a companion Mac app (QuotaBar for macOS, distributed outside the Mac App Store) through the user's private iCloud key-value store. No account or login is required in the iOS app.
> **To review without a Mac:** open the app → tap "데모 데이터로 둘러보기" (Browse with demo data) on the first screen, or Settings → "데모 데이터 보기". All screens and the widgets (Home Screen & Lock Screen) then show sample data.
> The app collects no personal data and contains no analytics, ads, or third-party SDKs.

## 5. 스크린샷 체크리스트
- 6.9" (iPhone 16/17 Pro Max) 1320×2868, 6.5" 1284×2778 필수. iPad를 지원하므로 13" iPad(2064×2752)도 필요.
- 권장 컷: ① 대시보드(데모 데이터) ② 서비스 카드 ③ 홈 화면 위젯 ④ 잠금 화면 위젯 ⑤ 온보딩.
- 시뮬레이터에서 설정 ▸ "데모 데이터 보기"를 켜고 촬영.

## 6. 제출 전 점검
- [ ] 실기기에서 Mac 미러링: Mac 새로고침 → iPhone 앱/위젯 반영 (iCloud 동기화는 수 초~1분 지연 가능)
- [ ] iCloud 로그아웃 상태에서 크래시 없이 온보딩 표시
- [ ] 다크/라이트, Dynamic Type 큰 글씨, VoiceOver에서 요소 읽기 확인
- [ ] 위젯 갤러리에서 6개 크기 모두 표시, 편집에서 쿼터 선택 가능
- [ ] 번들 버전/빌드 번호 증가 (`project.yml`의 `CFBundleVersion`)

## Apple Watch 앱
- `QuotaBarWatch` 타깃(watchOS 10+)은 iOS 앱에 임베드되어 함께 배포된다. 번들 ID `com.wevoid.quotabar.mobile.watchkitapp`.
- iPhone과 같은 iCloud 키-값 저장소(`<TeamID>.com.wevoid.quotabar`)를 직접 읽으므로 **Watch 타깃에도 같은 iCloud KVS entitlement**가 필요하다 (Developer 포털의 App ID에 iCloud 활성화).
- 컴플리케이션은 `QuotaBarWatchWidget` 익스텐션(번들 ID `….watchkitapp.widget`)이며, 이 타깃에도 iCloud KVS entitlement가 필요하다.
- 스크린샷: Apple Watch 지원 크기(Ultra 410×502 등) 중 필수 사이즈 하나 이상 제출. 심사용으로 앱 첫 화면의 "데모 보기"로 모든 화면을 확인할 수 있다.
