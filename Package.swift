// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "DesktopLyrics",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(url: "https://github.com/sindresorhus/KeyboardShortcuts", from: "2.0.0")
    ],
    targets: [
        .executableTarget(
            name: "DesktopLyrics",
            dependencies: [
                .product(name: "KeyboardShortcuts", package: "KeyboardShortcuts")
            ],
            path: "Sources/DesktopLyrics",
            linkerSettings: [
                .linkedFramework("ScriptingBridge")
            ]
        )
    ]
)
