#!/bin/bash

# Build script for Remotastic
# Make sure Xcode Command Line Tools are installed: xcode-select --install

set -e

echo "Building Remotastic..."

SWIFT_FILES=(
    "main.swift"
    "SiriRemoteApp.swift"
    "MenuBarManager.swift"
    "RemoteDetector.swift"
    "RemoteInputHandler.swift"
    "CursorController.swift"
    "MediaController.swift"
    "MediaKeyInterceptor.swift"
    "TouchHandler.swift"
)

# Find SDK path
SDK_PATH=$(xcrun --show-sdk-path --sdk macosx 2>/dev/null || echo "")

if [ -z "$SDK_PATH" ]; then
    echo "Error: macOS SDK not found. Please install Xcode Command Line Tools:"
    echo "  xcode-select --install"
    exit 1
fi

echo "Using SDK: $SDK_PATH"

# Detect architecture
ARCH=$(uname -m)
if [ "$ARCH" == "arm64" ]; then
    TARGET="arm64-apple-macosx11.0"
else
    TARGET="x86_64-apple-macosx11.0"
fi

echo "Building for: $TARGET"

# Build
swiftc \
    -sdk "$SDK_PATH" \
    -target "$TARGET" \
    -o Remotastic \
    "${SWIFT_FILES[@]}" \
    -import-objc-header SiriRemote-Bridging-Header.h \
    -F /System/Library/PrivateFrameworks \
    -framework IOKit \
    -framework CoreGraphics \
    -framework AudioToolbox \
    -framework Carbon \
    -framework AppKit \
    -framework MultitouchSupport

if [ $? -eq 0 ]; then
    echo ""
    echo "✓ Build successful!"
    echo ""
    echo "To create a proper macOS app bundle, run:"
    echo "  ./create_app_bundle.sh"
    echo ""
    echo "Or run directly with:"
    echo "  ./Remotastic"
else
    echo ""
    echo "✗ Build failed!"
    exit 1
fi
