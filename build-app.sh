#!/bin/zsh
# Empaqueta «A50 Control.app» (barra de menús, universal) en ./build y la firma ad-hoc.
# Uso: ./build-app.sh            → ./build/A50 Control.app
#      ./build-app.sh --instalar → además la copia a ~/Applications
set -euo pipefail
cd "$(dirname "$0")"

# Universal (Apple Silicon + Intel): la base Astro la usa gente con los dos.
swift build -c release --arch arm64 --arch x86_64 --product A50Control
swift build -c release --arch arm64 --arch x86_64 --product a50ctl
BIN=.build/apple/Products/Release

APP="build/A50 Control.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp -f "$BIN/A50Control" "$APP/Contents/MacOS/A50Control"
cp -f AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"   # se regenera con make-icon.swift + iconutil

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key><string>es.verticelabs.a50control</string>
    <key>CFBundleName</key><string>A50 Control</string>
    <key>CFBundleDisplayName</key><string>A50 Control</string>
    <key>CFBundleExecutable</key><string>A50Control</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>1.0</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>NSMicrophoneUsageDescription</key><string>Para probar cómo suena el micrófono de la A50 (la grabación se queda en este Mac y solo se analiza aquí).</string>
    <key>LSUIElement</key><true/>
    <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST

codesign --force --sign - --identifier es.verticelabs.a50control "$APP"
codesign --verify --verbose=1 "$APP"
echo "Hecho: $PWD/$APP"

if [[ "${1:-}" == "--instalar" ]]; then
    mkdir -p "$HOME/Applications"
    ditto "$APP" "$HOME/Applications/A50 Control.app"
    echo "Instalada en ~/Applications/A50 Control.app"
fi
