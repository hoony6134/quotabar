# CI/CD

## 워크플로
| 파일 | 트리거 | 하는 일 |
|---|---|---|
| `.github/workflows/ci.yml` | PR, `main` 푸시 | xcodegen → macOS 앱·위젯, iOS 앱 서명 없이 빌드 |
| `.github/workflows/release-mac.yml` | 태그 `v*` 푸시 / 수동 실행 | Developer ID 서명 → 공증 → DMG → GitHub Release |

## 릴리스 방법
```bash
git tag v2.1.0 && git push origin v2.1.0
```
버전은 태그에서, 빌드 번호는 Actions 실행 번호에서 가져온다. 수동 실행(workflow_dispatch)은 Release를 만들지 않고 공증된 DMG를 아티팩트로만 남긴다.

## GitHub Secrets (Settings → Secrets and variables → Actions)
| 이름 | 내용 |
|---|---|
| `DEVELOPER_ID_APP_P12_BASE64` | `Developer ID Application` 인증서(.p12)를 base64로 인코딩한 값 |
| `DEVELOPER_ID_APP_P12_PASSWORD` | 위 .p12 내보낼 때 정한 암호 |
| `DEVELOPER_ID_PROFILE_APP_BASE64` | `QuotaBar DeveloperID` 프로비저닝 프로파일(.provisionprofile)을 base64로 인코딩한 값 |
| `DEVELOPER_ID_PROFILE_WIDGET_BASE64` | `QuotaBar Widget DeveloperID` 프로파일을 base64로 인코딩한 값 |
| `ASC_KEY_P8_BASE64` | App Store Connect API 키(.p8)를 base64로 인코딩한 값 |
| `ASC_KEY_ID` | API 키 ID |
| `ASC_ISSUER_ID` | API 발급자 ID |

### 준비 방법
1. **인증서:** Xcode ▸ Settings ▸ Accounts ▸ Manage Certificates ▸ ＋ ▸ *Developer ID Application*. 키체인 접근에서 해당 인증서를 개인 키와 함께 .p12로 내보낸다.
2. **API 키:** App Store Connect ▸ 사용자 및 액세스 ▸ 통합 ▸ 팀 키 ▸ 생성(역할: Admin 또는 App Manager). .p8은 한 번만 내려받을 수 있다.
3. **인코딩 후 등록:**
   ```bash
   base64 -i DeveloperID.p12 | pbcopy   # 클립보드 → 시크릿에 붙여넣기
   base64 -i AuthKey_XXXX.p8 | pbcopy
   ```

## 참고
- 러너/Xcode: `macos-26` + Xcode 26 선택 단계. 코드가 iOS/macOS 26 API(`glassEffect` 등)를 써서 Xcode 16.x로는 컴파일되지 않는다.
- 프로비저닝: 아카이브·내보내기 단계는 API 키로 `-allowProvisioningUpdates`를 써서 Developer ID 프로파일(App Groups, iCloud KVS)을 자동 생성한다.
- iOS App Store 배포는 별도 (`docs/APP_STORE.md`).

> 릴리스는 클라우드 서명 대신 **수동 서명**(Developer ID 인증서 + 프로비저닝 프로파일)을 사용합니다. 프로파일은 `Config/DeveloperID.xcconfig`와 `Config/ExportOptions-DeveloperID.plist`의 이름과 일치해야 하며, 만료(2027-02) 전에 포털에서 재발급 후 시크릿을 갱신하세요. API 키는 notarytool 전용입니다.
