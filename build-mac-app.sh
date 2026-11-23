#!/bin/sh
set -eu

PROJECT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
SDK_PATH=${MACOS_SDK:-$(xcrun --sdk macosx --show-sdk-path)}
APP_DIR="$PROJECT_DIR/.build/相册清理.app"
ARCH=$(uname -m)

mkdir -p "$APP_DIR/Contents/MacOS"
mkdir -p "$PROJECT_DIR/.build/swift-module-cache"
swiftc \
    -sdk "$SDK_PATH" \
    -target "$ARCH-apple-macosx15.0" \
    -module-cache-path "$PROJECT_DIR/.build/swift-module-cache" \
    -parse-as-library \
    -o "$APP_DIR/Contents/MacOS/AlbumCleanupMac" \
    "$PROJECT_DIR/mac/AlbumCleanupMac.swift" \
    "$PROJECT_DIR/mac/ModelReview.swift" \
    "$PROJECT_DIR/mac/PreferenceLearning.swift" \
    "$PROJECT_DIR/mac/ReviewProtocol.swift" \
    -framework SwiftUI -framework Photos -framework AppKit -framework Security
cp "$PROJECT_DIR/mac/Info.plist" "$APP_DIR/Contents/Info.plist"
codesign --force --deep --sign - "$APP_DIR"

printf 'Built app: %s\n' "$APP_DIR"
