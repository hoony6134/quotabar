# 서비스별 사용량 조회 방식 (2026-10 기준)

모두 **비공식 엔드포인트**이며 예고 없이 바뀔 수 있다. 참고: [CodexBar](https://github.com/steipete/CodexBar)의 provider 문서(claude/codex/gemini/cursor/copilot). 깨지면 해당 계정 카드에 오류가 표시되고, 다른 서비스에는 영향이 없다.

| 서비스 | 1순위 | 폴백 | 비고 |
|---|---|---|---|
| **Claude** | `GET api.anthropic.com/api/oauth/usage` (Bearer + `anthropic-beta: oauth-2025-04-20`). 토큰은 `~/.claude/.credentials.json` → 키체인 `Claude Code-credentials`. 만료 시 refresh token → 실패 시 `claude` CLI 1회 실행 | claude.ai 웹 API: `sessionKey` 쿠키 → `/api/organizations` → `/api/organizations/{id}/usage` | `five_hour`, `seven_day`, `seven_day_sonnet`, `seven_day_routines/cowork`, `extra_usage` 윈도우를 응답에 있는 만큼 표시. Opus 별도 한도(`seven_day_opus`)는 폐지되어 무시하고, Max 플랜(응답 또는 자격증명의 `subscriptionType`로 감지)일 때만 `seven_day_fable`을 표시. 토큰에 `user:profile` 스코프 필요. 429는 Retry-After만큼 쉼 |
| **ChatGPT / Codex** | `GET chatgpt.com/backend-api/wham/usage` (Bearer + `ChatGPT-Account-Id`). `$CODEX_HOME/auth.json`, `config.toml`의 `chatgpt_base_url` 존중. id_token JWT에서 플랜 추출 | `codex -s read-only -a never app-server` JSON-RPC `account/rateLimits/read` (토큰 만료/401 시) | `rate_limit.primary_window`=5시간, `secondary_window`=주간, `additional_rate_limits[]`=모델별 추가. auth.json은 **쓰지 않는다**(갱신은 Codex CLI 몫) |
| **Cursor** | `GET cursor.com/api/usage-summary` (쿠키 `WorkosCursorSessionToken`). 포함 사용량·온디맨드(센트)·`billingCycleEnd` | 레거시 `/api/usage?user=` → `get-monthly-invoice`. 쿠키는 붙여넣기 또는 Cursor.app `state.vscdb`의 `cursorAuth/accessToken`(읽기 전용)으로 조립 | |
| **GitHub Copilot** | `GET api.github.com/copilot_internal/user` (`Authorization: token …`, 에디터 헤더). 토큰은 `~/.config/github-copilot/apps.json` → `gh auth token` | PAT 직접 입력 | `quota_snapshots.premium_interactions/chat/completions`, `percent_remaining`도 처리 |
| **Gemini** | Gemini CLI OAuth(`~/.gemini/oauth_creds.json`)로 `cloudcode-pa.googleapis.com/v1internal:retrieveUserQuota` (Pro/Flash/Flash Lite 모델별 `remainingFraction`) | `~/.gemini` 로컬 활동량 추정 (항상 함께 제공) | **2026-06-18부로 개인·AI Pro·Ultra 계정의 Gemini CLI OAuth가 종료**되어 이들은 `SUBSCRIPTION_REQUIRED(403)` → 자동으로 로컬 추정만 사용. Workspace/Code Assist 계정은 서버 값 |
| **Antigravity** | 로컬 상태 파일 활동량 추정 | — | 공개 잔량 API 없음 |

## 설계 원칙
- 자격증명은 앱 안에서 **읽기 전용**으로만 쓴다 (Claude는 회전된 refresh token을 원본에 되써서 Claude Code와 동기화하는 예외).
- 새 엔드포인트는 "있으면 쓰고 없으면 폴백" — 응답 필드가 없으면 `schemaChanged`로 보고하고 다음 경로로 내려간다.
- 호출 빈도는 기본 5분. 429 이후에는 Retry-After 동안 네트워크를 타지 않는다.
- iPhone에는 토큰이 아닌 **표시용 스냅샷만** iCloud 키-값 저장소로 전달한다 (`QuotaCloudSync`).
