// swift-tools-version: 5.9
// NOTE: This package does not include MultitouchSupport.framework (private API).
// Use build.sh for full trackpad support.

import PackageDescription

let package = Package(
    name: "HyperVibe",
    platforms: [.macOS(.v11)],
    products: [
        .executable(name: "HyperVibe", targets: ["HyperVibe"])
    ],
    targets: [
        .executableTarget(
            name: "HyperVibe",
            path: ".",
            sources: [
                "main.swift",
                "SiriRemoteApp.swift",
                "MenuBarManager.swift",
                "RemoteDetector.swift",
                "RemoteInputHandler.swift",
                "CursorController.swift",
                "MediaKeyInterceptor.swift",
                "TouchHandler.swift"
            ],
            linkerSettings: [
                .linkedFramework("IOKit"),
                .linkedFramework("CoreGraphics"),
                .linkedFramework("AudioToolbox"),
                .linkedFramework("Carbon"),
                .linkedFramework("AppKit")
            ]
        )
    ]
)
