#!/bin/sh
set -eu

PROJECT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
SDK_PATH=${MACOS_SDK:-$(xcrun --sdk macosx --show-sdk-path)}
ARCH=$(uname -m)

mkdir -p "$PROJECT_DIR/.build/swift-module-cache"
cp -R "$PROJECT_DIR/mac/Resources/." "$PROJECT_DIR/.build/"
swiftc \
    -D REVIEW_CHECKS \
    -sdk "$SDK_PATH" \
    -target "$ARCH-apple-macosx15.0" \
    -module-cache-path "$PROJECT_DIR/.build/swift-module-cache" \
    "$PROJECT_DIR/mac/AlbumCleanupMac.swift" \
    "$PROJECT_DIR/mac/ModelReview.swift" \
    "$PROJECT_DIR/mac/PreferenceLearning.swift" \
    "$PROJECT_DIR/mac/ReviewProtocol.swift" \
    "$PROJECT_DIR/mac/Localization.swift" \
    "$PROJECT_DIR/mac/tests/LocalizationChecks.swift" \
    "$PROJECT_DIR/mac/tests/LearningChecks.swift" \
    "$PROJECT_DIR/mac/tests/ReviewChecks.swift" \
    -o "$PROJECT_DIR/.build/review-checks" \
    -framework SwiftUI -framework Photos -framework AppKit -framework Security -framework ImageIO
"$PROJECT_DIR/.build/review-checks" "$@"
