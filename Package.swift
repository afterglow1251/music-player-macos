// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "WinampMac",
    platforms: [
        .macOS(.v14)
    ],
    targets: [
        .executableTarget(
            name: "WinampMac",
            path: "Sources/WinampMac",
            swiftSettings: [
                // Never let a compiler warning slip by unnoticed — surface issues
                // (unused values, deprecations, concurrency) at build time.
                .unsafeFlags(["-warnings-as-errors"])
            ]
        )
    ]
)
