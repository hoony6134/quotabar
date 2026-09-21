# QuotaBar

AI 구독 서비스들의 사용량 한도(쿼터)를 한 곳에서 추적하는 macOS 앱.
대시보드 윈도우와 메뉴막대 양쪽에서 세션·일간·주간·월간 제한을 한눈에 확인할 수 있다.

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

### 데스크톱 위젯 빌드 (WidgetKit)

위젯 익스텐션은 SPM으로 빌드할 수 없어 Xcode 프로젝트가 필요하다. XcodeGen 설정(`project.yml`)을 준비해뒀다:

```bash
brew install xcodegen     # 없으면
xcodegen generate
open QuotaBar.xcodeproj   # Signing & Capabilities에서 Team 선택 후 Run
```

빌드 후 위젯 갤러리(데스크톱 우클릭 → 위젯 편집)에 "AI 쿼터" 위젯이 나타난다.
small(최고 사용률 링), medium(상위 4개 바), large(상위 10개) 세 가지 크기를 지원한다.
앱과 위젯은 App Group(`group.com.wevoid.quotabar`)으로 데이터를 공유한다 —
macOS 15+에서 그룹 ID 검증 문제가 생기면 `WidgetShared.swift`와 `project.yml` 두 곳의 그룹 ID를
`<팀ID>.com.wevoid.quotabar` 형태로 바꿀 것.

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
cursor.com 로그인 → 개발자도구 → Application → Cookies → `WorkosCursorSessionToken` 값을 붙여넣기.
요금제 개편이 잦아 레거시 요청 카운트와 월 인보이스($) 두 엔드포인트를 모두 시도한다.

### GitHub Copilot (Edu) — 자동
GitHub PAT(classic, `read:user` 권한)를 붙여넣기.
`api.github.com/copilot_internal/user`의 quota_snapshots에서 프리미엄 요청(월 300회) 잔량과 리셋일을 받아온다.

### Gemini · Antigravity — 로컬 자동 추정
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

### 배포 (직접 배포 — Developer ID)

App Store는 샌드박스가 강제돼 자동 감지 기능 대부분이 막히므로 **직접 배포**를 사용한다:

1. `xcodegen generate` (project.yml 변경 후 1회) → Xcode에서 Product → Archive
2. Organizer → Distribute App → **Direct Distribution** → 공증(notarization) 업로드 → 완료 후 Export
3. 유료 Apple Developer Program 계정과 Developer ID 인증서 필요 (Xcode가 자동 발급)
4. 공증 없이 개인 사용만 할 거면 Archive → Copy App으로 .app만 꺼내면 된다

Hardened Runtime은 project.yml에 설정돼 있다. 샌드박스는 켜지 않는다 — 켜면 ~/.claude, ~/.codex, ~/.gemini 읽기와 키체인 조회가 막힌다.

## 트러블슈팅

**앱을 켤 때마다 키체인 접근 창이 뜨는 경우** — ad-hoc 서명은 빌드할 때마다 서명이 바뀌어 macOS가 기존 키체인 항목을 다른 앱의 것으로 취급하기 때문이다. 완화책이 적용돼 있다: 자동 감지 모드는 키체인을 아예 사용하지 않고, 직접 붙여넣은 토큰(Cursor/Copilot)만 키체인에 저장하며 세션당 1회만 읽는다. 그래도 창이 뜨면 (1) 창에서 **항상 허용**을 누르거나, (2) Xcode에서 본인 Team으로 서명하면(서명이 고정됨) 재발하지 않는다. Claude 자격증명 감지는 파일(`~/.claude/.credentials.json`)을 우선 읽고, 파일이 없을 때만 키체인을 조회한다 — 이때 뜨는 창은 `security` 도구에 대한 것이라 **항상 허용**이 영구 적용된다.

## 주의

- Claude·Codex·Cursor·Copilot 연동은 **비공식 엔드포인트**라 예고 없이 깨질 수 있다. 깨지면 해당 계정 카드에 오류가 표시된다.
- Anthropic은 2026년 2월부터 OAuth 토큰 사용을 공식 클라이언트로 제한하는 정책을 도입했다. 조회 빈도를 보수적으로(기본 5분) 유지할 것.

## 구조

```
Sources/QuotaBar/
├── QuotaBarApp.swift          # 앱 진입점 (Window + MenuBarExtra + Settings)
├── Models/
│   ├── Models.swift           # ServiceKind, ResetPeriod, QuotaDef/State, Account
│   ├── DefaultQuotas.swift    # 서비스별 기본 쿼터 카탈로그
│   └── AppStore.swift         # 상태/영속화/타이머/리셋 롤오버
├── Connectors/
│   ├── Connector.swift        # 프로토콜 + HTTP/날짜 유틸
│   ├── ClaudeConnector.swift  # oauth/usage (5h·7d utilization)
│   ├── ChatGPTConnector.swift # Codex wham/usage
│   ├── GeminiConnector.swift  # ~/.gemini activity estimate
│   ├── AntigravityConnector.swift # ~/.gemini/antigravity activity estimate
│   ├── CursorConnector.swift  # api/usage + monthly-invoice
│   └── CopilotConnector.swift # copilot_internal/user
├── Views/                     # 대시보드, 메뉴막대, 계정 추가/설정
└── Util/                      # Keychain, NotificationManager, WidgetShared/Writer
Sources/QuotaBarWidget/        # WidgetKit 익스텐션 (small/medium/large)
Resources/                     # AppIcon.icns + iconset
project.yml                    # XcodeGen 설정 (앱 + 위젯 타깃)
```
