# QuotaBar 개인정보 처리방침 / Privacy Policy

최종 수정: 2026-11-18

## 한국어

QuotaBar(macOS·iOS)는 사용자가 구독 중인 AI 서비스의 **사용량 한도(쿼터)를 보여 주는** 앱입니다.

- **수집하는 개인정보: 없음.** 개발자는 어떤 서버도 운영하지 않으며, 사용자의 데이터를 수집·저장·판매·공유하지 않습니다.
- **분석·광고·추적 SDK를 사용하지 않습니다.**
- **Mac 앱**은 사용자의 Mac에 이미 저장된 로그인 정보(예: Claude Code·Codex·Cursor·GitHub Copilot의 로컬 자격증명)를 읽어 각 서비스의 공식/비공식 사용량 API에 **사용자 기기에서 직접** 요청합니다. 토큰은 Mac 안에서만 쓰이며 외부 서버로 전송되지 않습니다. 직접 붙여넣은 토큰과 '브라우저로 로그인'으로 받은 Claude 토큰은 macOS 키체인에 저장됩니다.
- **iPhone 미러링:** Mac 앱은 *표시용 데이터*(서비스 이름, 쿼터 이름, 사용률 %, 리셋 시각, 계정 라벨)만 사용자의 **개인 iCloud(키-값 저장소)** 로 동기화합니다. 이 데이터는 사용자의 Apple ID로만 접근할 수 있으며 개발자는 볼 수 없습니다. **토큰·쿠키·비밀번호는 동기화되지 않습니다.** Mac 설정에서 미러링을 끌 수 있습니다.
- **iPhone에서 직접 조회(선택):** iPhone 앱에서 Claude 계정에 브라우저로 로그인하면, 받은 토큰은 **그 iPhone의 키체인에만** 저장되고(iCloud로 동기화되거나 기기 밖으로 옮겨지지 않음) iPhone이 Anthropic의 사용량 API에 **직접** 요청합니다. 개발자 서버를 거치지 않습니다. 이 로그인에 필요한 공개 설정값(클라이언트 ID·로그인 주소, 비밀이 아님)은 Mac 앱이 개인 iCloud로 전달합니다. 설정에서 계정을 지우거나 앱을 삭제하면 토큰도 삭제됩니다.
- iOS 앱과 위젯은 iCloud에서 받은 표시용 데이터와 iPhone이 직접 조회한 사용률을 기기 내 App Group 저장소에 보관합니다. 앱을 삭제하면 함께 삭제됩니다.

문의: https://github.com/hoony6134/quotabar/issues

## English

QuotaBar (macOS & iOS) shows the usage limits of the AI subscriptions you already use.

- **No personal data is collected.** The developer runs no servers and does not collect, store, sell, or share your data.
- **No analytics, advertising, or tracking SDKs.**
- The **Mac app** reads sign-in data already stored on your Mac (e.g. local credentials of Claude Code, Codex, Cursor, GitHub Copilot) and calls each service's usage endpoint **directly from your device**. Tokens never leave your Mac. Tokens you paste manually and Claude tokens from "Log in with browser" are stored in the macOS Keychain.
- **iPhone mirroring:** the Mac app syncs only *display data* (service name, quota name, usage percentage, reset time, account label) through **your private iCloud key-value store**. It is accessible only with your Apple ID and not visible to the developer. **Tokens, cookies, and passwords are never synced.** Mirroring can be turned off in the Mac app's settings.
- **Direct fetch on iPhone (optional):** if you log in to a Claude account from the iPhone app, the resulting tokens are stored **only in that iPhone's Keychain** (never synced through iCloud or moved off the device), and the iPhone calls Anthropic's usage endpoint **directly**. No developer server is involved. The public settings this login needs (client ID and login URLs, not secrets) are passed from the Mac app through your private iCloud. Removing the account in Settings or deleting the app deletes the tokens.
- The iOS app and widgets keep the mirrored display data and the usage fetched on the iPhone in an on-device App Group container; deleting the app removes it.

Contact: https://github.com/hoony6134/quotabar/issues
