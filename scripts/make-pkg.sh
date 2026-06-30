#!/bin/bash
# 공증된 QuotaBar.app → 배포용 .pkg 인스톨러
#
# 사전 준비:
# 1. Developer ID Installer 인증서 (앱 서명용 'Developer ID Application'과 다름!)
#    Xcode → Settings → Accounts → Manage Certificates → + → Developer ID Installer
# 2. notarytool 자격증명 프로필 (최초 1회):
#    xcrun notarytool store-credentials quotabar \
#      --apple-id <애플ID이메일> --team-id 2S9H42VJUA --password <앱암호>
#    (앱 암호는 appleid.apple.com → 로그인 및 보안 → 앱 암호에서 생성)
#
# 사용법: ./scripts/make-pkg.sh <공증된 QuotaBar.app 경로> [버전]
set -euo pipefail

APP="${1:?사용법: ./scripts/make-pkg.sh <QuotaBar.app 경로> [버전]}"
VERSION="${2:-1.0.0}"
TEAM_ID="2S9H42VJUA"
PROFILE="quotabar"   # notarytool store-credentials에서 지정한 프로필명
PKG="QuotaBar-${VERSION}.pkg"

# 주의: `|| true`가 없으면 grep 미스 시 set -e가 여기서 조용히 종료시켜 버린다.
INSTALLER_IDENTITY=$(security find-identity -v 2>/dev/null | grep "Developer ID Installer" | head -1 | sed 's/.*"\(.*\)"/\1/' || true)
if [ -z "$INSTALLER_IDENTITY" ]; then
  echo "✗ 'Developer ID Installer' 인증서가 없습니다."
  echo "  → Xcode → Settings → Accounts → (팀 선택) → Manage Certificates → ＋ → 'Developer ID Installer'"
  echo "  (앱 서명용 'Developer ID Application'과는 다른 인증서입니다.)"
  exit 1
fi
echo "▸ 서명 인증서: $INSTALLER_IDENTITY"

# notarytool 프로필 확인 (pkg 공증에 필요)
if ! xcrun notarytool history --keychain-profile "$PROFILE" >/dev/null 2>&1; then
  echo "✗ notarytool 프로필 '$PROFILE'가 없습니다. 최초 1회 설정:"
  echo "  xcrun notarytool store-credentials $PROFILE \\"
  echo "    --apple-id <애플ID이메일> --team-id $TEAM_ID --password <앱전용암호>"
  exit 1
fi

# 0) 앱에 공증 티켓이 스테이플돼 있는지 확인 (오프라인 검증용)
if ! xcrun stapler validate "$APP" >/dev/null 2>&1; then
  echo "▸ 앱에 공증 티켓 스테이플 시도"
  xcrun stapler staple "$APP" || echo "  (Organizer에서 Export한 앱이면 이미 스테이플돼 있을 수 있음)"
fi

# 1) pkg 생성 + 서명
echo "▸ pkgbuild"
pkgbuild --component "$APP" \
         --install-location /Applications \
         --identifier com.wevoid.quotabar \
         --version "$VERSION" \
         --sign "$INSTALLER_IDENTITY" \
         "$PKG"

# 2) pkg 자체 공증 (앱 공증과 별개)
echo "▸ notarize (수 분 소요)"
xcrun notarytool submit "$PKG" --keychain-profile "$PROFILE" --wait

# 3) 공증 티켓 스테이플
echo "▸ staple"
xcrun stapler staple "$PKG"

echo "✓ 완료: $PKG"
echo "  검증: spctl -a -vv -t install $PKG"
