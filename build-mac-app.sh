#!/bin/sh
set -eu

PROJECT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
SDK_PATH=${MACOS_SDK:-$(xcrun --sdk macosx --show-sdk-path)}
APP_DIR="$PROJECT_DIR/.build/ByePhoto.app"
ARCH=$(uname -m)

mkdir -p "$APP_DIR/Contents/MacOS"
mkdir -p "$APP_DIR/Contents/Resources"
mkdir -p "$PROJECT_DIR/.build/swift-module-cache"
swiftc \
    -sdk "$SDK_PATH" \
    -target "$ARCH-apple-macosx15.0" \
    -module-cache-path "$PROJECT_DIR/.build/swift-module-cache" \
    -parse-as-library \
    -o "$APP_DIR/Contents/MacOS/ByePhoto" \
    "$PROJECT_DIR/mac/AlbumCleanupMac.swift" \
    "$PROJECT_DIR/mac/ModelReview.swift" \
    "$PROJECT_DIR/mac/PreferenceLearning.swift" \
    "$PROJECT_DIR/mac/ReviewProtocol.swift" \
    "$PROJECT_DIR/mac/Localization.swift" \
    -framework SwiftUI -framework Photos -framework AppKit -framework Security
cp "$PROJECT_DIR/mac/Info.plist" "$APP_DIR/Contents/Info.plist"
cp -R "$PROJECT_DIR/mac/Resources/." "$APP_DIR/Contents/Resources/"
ICON_SET="$PROJECT_DIR/.build/AppIcon.iconset"
mkdir -p "$ICON_SET"
for size in 16 32 128 256 512; do
    sips -z "$size" "$size" "$PROJECT_DIR/mac/Assets/AppIcon.png" \
        --out "$ICON_SET/icon_${size}x${size}.png" >/dev/null
    retina=$((size * 2))
    sips -z "$retina" "$retina" "$PROJECT_DIR/mac/Assets/AppIcon.png" \
        --out "$ICON_SET/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil -c icns "$ICON_SET" -o "$APP_DIR/Contents/Resources/AppIcon.icns"
codesign --force --deep --sign - "$APP_DIR"
touch "$APP_DIR"

printf 'Built app: %s\n' "$APP_DIR"
