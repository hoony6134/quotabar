# QuotaBar 2.0

AI 구독 서비스들의 사용량 한도(쿼터)를 한 곳에서 추적하는 macOS 앱 + **iPhone 미러링 앱·위젯**.
대시보드 윈도우와 메뉴막대, iPhone 홈·잠금 화면에서 세션·일간·주간·월간 제한을 한눈에 확인할 수 있다.

## 2.0 변경점

- **iPhone 앱 + 위젯** (`QuotaBarMobile`): Mac이 조회한 사용률을 iCloud(키-값 저장소)로 미러링. 홈 화면(S/M/L)·잠금 화면(원형/직사각형/인라인) 위젯, 당겨서 새로고침(Mac에 갱신 요청), 데모 모드(App Review/체험용). **토큰은 iPhone으로 가지 않는다.**
- **조회 방식 최신화** — Claude(추가 윈도우·extra usage·claude.ai 세션 폴백), Codex(`$CODEX_HOME`·JWT 플랜·app-server 폴백), Cursor(`usage-summary`·Cursor.app 로그인 자동 감지), Copilot(에디터 로그인/`gh` 자동 감지), Gemini(Code Assist 서버 잔량 + 로컬 추정). 자세한 내용은 [docs/FETCHING.md](docs/FETCHING.md).
- **새 디자인** — 단계 색 체계(민트→앰버→오렌지→레드)·링 게이지·요약 히어로·새 앱 아이콘, 위젯 리셋 시각에 맞춘 타임라인.
- 배포: macOS는 Developer ID 직접 배포, **iOS는 App Store** ([docs/APP_STORE.md](docs/APP_STORE.md), [개인정보 처리방침](docs/PRIVACY.md)).

지원 서비스 (기본 등록): **Claude (Max) · ChatGPT/Codex (Plus) · Gemini (AI Pro) · Antigravity (AI Pro) · Cursor (Pro) · GitHub Copilot (Edu)**

## 기능

- 서비스별 **여러 계정** 연동 (라벨로 구분: 개인/회사 등)
- **자동 동기화/감지** — Claude, Codex, Cursor, GitHub Copilot은 사용량 엔드포인트를 조회하고 Gemini, Antigravity는 로컬 활동 기록을 자동 추정
- **수동 사용량 입력 제거** — 사용량은 커넥터 갱신값만 반영하고, 한도 값만 계정 설정에서 수정 가능
- 메뉴막대에 **최고 사용률 %** 표시, 클릭하면 전체 계정 컴팩트 뷰
- 사용률 색상 단계: 50% 미만 초록 → 75% 노랑 → 90% 주황 → 이상 빨강
- 토큰은 **macOS 키체인**에만 저장, 사용량 데이터는 `~/Library/Application Support/QuotaBar/accounts.json`

## 빌드 & 실행

요구사항: macOS 14+, Xcode 15+ (또는 Swift 5.9+ 툴체인)

```bash
# 개발 실행
swift run

# .app 번들 생성 (build/QuotaBar.app)
./scripts/build-app.sh
open build/QuotaBar.app
```

Xcode에서 열려면 `Package.swift`를 더블클릭하면 된다.

### Xcode 프로젝트 (macOS 위젯 + iOS 앱/위젯)

위젯 익스텐션과 iOS 앱은 SPM으로 빌드할 수 없어 Xcode 프로젝트가 필요하다. `QuotaBar.xcodeproj`는 **생성물**이라 저장소에 두지 않는다 — XcodeGen 설정(`project.yml`)으로 만든다:

```bash
brew install xcodegen     # 없으면
xcodegen generate
open QuotaBar.xcodeproj   # Signing & Capabilities에서 Team 선택 후 Run
```

스킴: `QuotaBar`(macOS 앱+위젯), `QuotaBarMobile`(iOS 앱+위젯). 빌드 후 위젯 갤러리에 "QuotaBar" 위젯이 나타난다.
macOS는 small/medium/large, iOS는 여기에 잠금 화면 위젯(원형·직사각형·인라인)이 추가된다. 표시할 쿼터는 위젯 편집에서 고를 수 있다.
앱과 위젯은 App Group(`group.com.wevoid.quotabar`)으로 데이터를 공유한다 —
macOS 15+에서 그룹 ID 검증 문제가 생기면 `Shared/QuotaSnapshot.swift`와 `project.yml` 두 곳의 그룹 ID를
`<팀ID>.com.wevoid.quotabar` 형태로 바꿀 것.

### iPhone 미러링 (iCloud)

Mac 앱이 새로고침할 때마다 표시용 스냅샷(사용률·리셋 시각·라벨, 수 KB)을 `NSUbiquitousKeyValueStore`에 쓴다. iPhone 앱/위젯은 같은 Apple ID의 iCloud에서 그것을 읽는다. 별도 서버·로그인이 없다.

- 필요: Mac·iPhone 모두 같은 Apple ID + iCloud 로그인, 세 타깃(Mac 앱, iOS 앱, iOS 위젯)이 같은 KVS 컨테이너(`<TeamID>.com.wevoid.quotabar`)를 가질 것 → [docs/APP_STORE.md](docs/APP_STORE.md)의 사전 준비 참고.
- iPhone에서 당겨서 새로고침 → iCloud로 요청 → Mac이 즉시 갱신 후 다시 올림(Mac이 꺼져 있으면 마지막 값 + "오래됨" 표시).
- Mac 설정 → iPhone → 미러링 끄기 가능. 동기화 지연은 수 초~1분 정도일 수 있다.
- 공유 코드는 `Sources/QuotaBar/Shared/` (스냅샷 모델, 동기화 채널, 디자인 토큰, 링/바 컴포넌트) — macOS 앱·macOS 위젯·iOS 앱·iOS 위젯 네 타깃이 함께 컴파일한다.

### 앱 아이콘

`Resources/AppIcon.icns` (게이지 모티프, 자동 생성). `scripts/build-app.sh`와 Xcode 프로젝트 양쪽에 연결돼 있다.
수정하려면 `Resources/AppIcon.iconset/`의 PNG를 교체하고 macOS에서 `iconutil -c icns Resources/AppIcon.iconset -o Resources/AppIcon.icns`.

### 서비스 로고

앱 내 서비스 배지는 실제 제품 로고를 사용한다 — `Sources/QuotaBar/Resources/Logos/<ServiceKind.rawValue>.png`
(흰색 256px, [@lobehub/icons](https://github.com/lobehub/lobe-icons) MIT 라이선스에서 렌더링).
로고 파일이 없으면 SF Symbol로 폴백한다.

## 서비스별 연동 방법

### Claude (Max) — 자동
계정 추가 시 **자동 감지** 버튼: Claude Code 자격증명(키체인 `Claude Code-credentials`, `~/.claude/.credentials.json`, `~/.claude.json` 등)에서 OAuth 토큰을 매 갱신마다 다시 찾는다.
`api.anthropic.com/api/oauth/usage`에서 5시간 세션 / 주간(전체) / 주간(Opus) 사용률(%)과 리셋 시각을 받아온다.

**토큰 만료 시 자동 재발급(하이브리드).** Claude Code 토큰은 Claude Code가 실행될 때만 갱신되므로, 앱이 만료(또는 401/403)를 감지하면 다음 순서로 직접 재발급한다:
1. 저장된 `refreshToken`으로 `console.anthropic.com/v1/oauth/token`에 직접 갱신 요청 (빠르고 쿼터 소모 없음)
2. 실패하면 `claude` CLI를 비대화식으로 한 번 실행해 Claude Code가 스스로 갱신하게 함

재발급에 성공하면 회전된 토큰을 읽어온 원본(파일/키체인)에 **다시 써서 Claude Code와 동기화**한다 — 안 그러면 refresh token 회전 때문에 Claude Code 자신의 로그인이 깨질 수 있다. (키체인이 원본이면 갱신 저장 시 키체인 접근 창이 한 번 뜰 수 있으니 **항상 허용** 권장.)

### ChatGPT/Codex (Plus) — 자동
`~/.codex/auth.json`의 Codex 자격증명을 실시간으로 읽고 `chatgpt.com/backend-api/wham/usage`에서 Codex 5시간/주간 한도 사용률을 받아온다.

### Cursor (Pro) — 자동
**자동 감지**: 설치된 Cursor 앱의 로그인 상태(`state.vscdb`, 읽기 전용)에서 쿠키를 조립한다. 앱이 없다면 cursor.com 로그인 → 개발자도구 → Application → Cookies → `WorkosCursorSessionToken` 값을 붙여넣기.
`/api/usage-summary`(포함 사용량·온디맨드·청구 주기)를 먼저, 레거시 요청 카운트와 월 인보이스는 폴백으로 시도한다.

### GitHub Copilot (Edu) — 자동
**자동 감지**: VS Code 등 에디터의 Copilot 로그인(`~/.config/github-copilot/apps.json`) 또는 `gh auth token`. 직접 입력하려면 GitHub 토큰(`read:user`)을 붙여넣기.
`api.github.com/copilot_internal/user`의 quota_snapshots에서 프리미엄 요청(월 300회) 잔량과 리셋일을 받아온다.

### Gemini · Antigravity — 서버 잔량(가능한 계정) + 로컬 자동 추정
Gemini는 Gemini CLI OAuth로 Code Assist `retrieveUserQuota`(모델별 잔량)를 먼저 시도한다. 단, Google이 2026-06-18부로 개인·AI Pro·Ultra 계정의 Gemini CLI OAuth를 종료해 이런 계정은 자동으로 로컬 추정으로 내려간다.
Google이 앱 잔량 API를 공개하지 않아 `~/.gemini` 및 `~/.gemini/antigravity` 로컬 기록을 읽어 최근 활동량을 추정한다. 서버가 계산하는 실제 compute quota와 다를 수 있다.

기본 한도(설정에서 수정 가능):

| 서비스 | 쿼터 | 기본 한도 | 주기 |
|---|---|---|---|
| Codex Plus | Codex 세션 | 100% | 5시간 |
| Codex Plus | Codex 주간 | 100% | 주간 |
| Gemini AI Pro | Gemini 활동 | 100회 | 5시간/일간 |
| Gemini AI Pro | Deep Research | 20회 | 일간 |
| Antigravity AI Pro | Agent 활동 | 100회 | 5시간/일간 |
| Antigravity AI Pro | Agent 활동 | 1,000회 | 월간 |

한도 수치는 2026년 6월 공개 정보 기준이며 서비스가 수시로 변경하므로, 계정 카드의 ⚙︎ → 한도 편집에서 맞춰 쓰면 된다.

### 배포

- **macOS — Developer ID 직접 배포.** Mac App Store는 샌드박스가 강제돼 `~/.claude`·`~/.codex` 읽기와 키체인 조회가 막히므로 쓰지 않는다.
  1. `xcodegen generate` → Xcode에서 스킴 `QuotaBar` → Product → Archive
  2. Organizer → Distribute App → **Direct Distribution** → 공증(notarization) → Export
  3. Hardened Runtime은 `project.yml`에 설정돼 있다. 앱 샌드박스는 켜지 않는다.
- **iOS — App Store.** 스킴 `QuotaBarMobile` → Archive → App Store Connect. 메타데이터·심사 메모·체크리스트는 [docs/APP_STORE.md](docs/APP_STORE.md).

## 트러블슈팅

**앱을 켤 때마다 키체인 접근 창이 뜨는 경우** — ad-hoc 서명은 빌드할 때마다 서명이 바뀌어 macOS가 기존 키체인 항목을 다른 앱의 것으로 취급하기 때문이다. 완화책이 적용돼 있다: 자동 감지 모드는 키체인을 아예 사용하지 않고, 직접 붙여넣은 토큰(Cursor/Copilot)만 키체인에 저장하며 세션당 1회만 읽는다. 그래도 창이 뜨면 (1) 창에서 **항상 허용**을 누르거나, (2) Xcode에서 본인 Team으로 서명하면(서명이 고정됨) 재발하지 않는다. Claude 자격증명 감지는 파일(`~/.claude/.credentials.json`)을 우선 읽고, 파일이 없을 때만 키체인을 조회한다 — 이때 뜨는 창은 `security` 도구에 대한 것이라 **항상 허용**이 영구 적용된다.

## 주의

- Claude·Codex·Cursor·Copilot 연동은 **비공식 엔드포인트**라 예고 없이 깨질 수 있다. 깨지면 해당 계정 카드에 오류가 표시된다.
- Anthropic은 2026년 2월부터 OAuth 토큰 사용을 공식 클라이언트로 제한하는 정책을 도입했다. 조회 빈도를 보수적으로(기본 5분) 유지할 것.

## 구조

```
Sources/QuotaBar/                  # macOS 앱 (SPM 실행 타깃이기도 함)
├── QuotaBarApp.swift              # 앱 진입점 (Window + MenuBarExtra + Settings)
├── Models/                        # ServiceKind, 쿼터 모델, 기본 쿼터, AppStore(+iPhone 갱신 요청 수신)
├── Connectors/                    # Claude · ChatGPT(Codex) · Gemini · Antigravity · Cursor · Copilot
├── Views/                         # 대시보드(요약 히어로), 메뉴막대, 계정 추가/설정
├── Util/                          # Keychain, 알림, WidgetSnapshotWriter(앱그룹 + iCloud 기록)
└── Shared/                        # ★ 4개 타깃 공용
    ├── QuotaSnapshot.swift        #   스냅샷 모델 v2, 앱 그룹 경로, 데모 데이터
    ├── QuotaCloudSync.swift       #   iCloud KVS 채널 (Mac→iPhone 스냅샷, iPhone→Mac 갱신 요청)
    └── QuotaTheme.swift           #   색 단계, 포맷터, 로고/링/바 컴포넌트
Sources/QuotaBarWidget/            # WidgetKit 위젯 — macOS·iOS 공용 소스 (iOS는 잠금 화면 위젯 포함)
Sources/QuotaBarMobile/            # iOS 앱 (대시보드, 온보딩, 설정, 데모 모드, 에셋, PrivacyInfo)
Config/                            # Info.plist / entitlements (macOS, iOS)
docs/                              # FETCHING.md · APP_STORE.md · PRIVACY.md
Resources/                         # macOS 앱 아이콘
project.yml                        # XcodeGen 설정 (macOS 앱·위젯 + iOS 앱·위젯)
```
