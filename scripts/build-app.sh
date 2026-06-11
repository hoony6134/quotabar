#!/bin/bash
# QuotaBar.app 번들 빌드 스크립트
# 사용법: ./scripts/build-app.sh  →  build/QuotaBar.app 생성
set -euo pipefail

cd "$(dirname "$0")/.."

echo "▸ swift build -c release"
swift build -c release

APP="build/QuotaBar.app"
BIN="$(swift build -c release --show-bin-path)/QuotaBar"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cp "$BIN" "$APP/Contents/MacOS/QuotaBar"

# SPM 리소스 번들 (서비스 로고 등) — 없으면 Bundle.module 접근 시 크래시한다
BIN_DIR="$(swift build -c release --show-bin-path)"
if [ -d "$BIN_DIR/QuotaBar_QuotaBar.bundle" ]; then
  cp -R "$BIN_DIR/QuotaBar_QuotaBar.bundle" "$APP/Contents/Resources/"
fi

# 앱 아이콘
if [ -f "Resources/AppIcon.icns" ]; then
  cp "Resources/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
fi

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>
    <string>QuotaBar</string>
    <key>CFBundleIdentifier</key>
    <string>com.wevoid.quotabar</string>
    <key>CFBundleName</key>
    <string>QuotaBar</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>LSApplicationCategoryType</key>
    <string>public.app-category.developer-tools</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0.0</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
    <key>NSHighResolutionCapable</key>
    <true/>
</dict>
</plist>
PLIST

echo "▸ codesign (ad-hoc)"
codesign --force --deep --sign - "$APP"

echo "✓ 완료: $APP"
echo "  실행:        open $APP"
echo "  앱 폴더 설치: cp -R $APP /Applications/"
