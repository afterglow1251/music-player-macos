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
            path: "Sources/WinampMac"
        )
    ]
)
