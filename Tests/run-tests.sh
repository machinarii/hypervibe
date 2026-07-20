#!/bin/bash
# Runs the standalone tests for RemoteTouchSurface (mc-25ko: trackpad-vs-remote
# gesture discrimination). Mirrors build.sh's direct-swiftc style rather than SwiftPM,
# since RemoteTouchSurface.swift has no framework dependencies and needs none of
# build.sh's private-framework/bridging-header setup.

set -e

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(dirname "$DIR")"
OUT="$(mktemp -d)/RemoteTouchSurfaceTests"

SDK_PATH=$(xcrun --show-sdk-path --sdk macosx 2>/dev/null || echo "")
if [ -z "$SDK_PATH" ]; then
    echo "Error: macOS SDK not found. Please install Xcode Command Line Tools."
    exit 1
fi

swiftc \
    -sdk "$SDK_PATH" \
    -o "$OUT" \
    "$ROOT/RemoteTouchSurface.swift" \
    "$DIR/RemoteTouchSurfaceTestCases.swift" \
    "$DIR/main.swift"

"$OUT"
