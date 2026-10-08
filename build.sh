#!/bin/bash
# Bottari.app 을 빌드한다.   ./build.sh            → build/Bottari.app
#                       ./build.sh install    → /Applications 에 설치하고 Finder 서비스 등록
#                       ./build.sh dmg        → build/Bottari.dmg
set -euo pipefail
cd "$(dirname "$0")"

swift build -c release --product Bottari
BIN="$(swift build -c release --show-bin-path)/Bottari"

APP="build/Bottari.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Bottari"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp LICENSE THIRD_PARTY_LICENSES.md "$APP/Contents/Resources/"

ICONSET="build/AppIcon.iconset"
rm -rf "$ICONSET"
swift scripts/make_icon.swift "$ICONSET"
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"

# Apple Developer 서명은 하지 않는다. (arm64 에서 실행되려면 필요한 ad-hoc 서명만 적용)
codesign --force --deep --sign - "$APP"
echo "빌드 완료: $APP"

if [ "${1:-}" = "install" ]; then
    DEST="/Applications/Bottari.app"
    rm -rf "$DEST"
    cp -R "$APP" "$DEST"
    xattr -dr com.apple.quarantine "$DEST" 2>/dev/null || true
    /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$DEST"
    /System/Library/CoreServices/pbs -update 2>/dev/null || true
    echo "설치 완료: $DEST"
    echo "Finder 우클릭 메뉴(서비스/빠른 동작)가 보이지 않으면: 시스템 설정 ▸ 키보드 ▸ 키보드 단축키 ▸ 서비스 ▸ 파일 및 폴더 에서 Bottari 항목을 켜세요."
fi

if [ "${1:-}" = "dmg" ]; then
    STAGE="build/dmg"
    rm -rf "$STAGE" build/Bottari.dmg
    mkdir -p "$STAGE"
    cp -R "$APP" "$STAGE/"
    ln -s /Applications "$STAGE/Applications"
    cp LICENSE THIRD_PARTY_LICENSES.md "$STAGE/"
    cat > "$STAGE/처음 실행하기.txt" <<'TXT'
1. Bottari.app 을 Applications 폴더로 끌어다 놓으세요.
2. 이 앱은 Apple 개발자 서명이 없습니다. 처음 실행할 때 "열 수 없음" 이 뜨면
   - 앱을 우클릭 ▸ 열기 ▸ 열기, 또는
   - 터미널에서: xattr -dr com.apple.quarantine /Applications/Bottari.app
3. Finder 우클릭 메뉴: 시스템 설정 ▸ 키보드 ▸ 키보드 단축키 ▸ 서비스 ▸ 파일 및 폴더 에서 Bottari 항목을 켜세요.
TXT
    hdiutil create -volname "Bottari" -srcfolder "$STAGE" -ov -format UDZO build/Bottari.dmg >/dev/null
    rm -rf "$STAGE"
    echo "DMG 생성 완료: build/Bottari.dmg"
fi
