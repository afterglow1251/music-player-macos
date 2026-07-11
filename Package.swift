// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Sonar",
    platforms: [
        .macOS(.v14)
    ],
    targets: [
        .executableTarget(
            name: "Sonar",
            path: "Sources/Sonar",
            swiftSettings: [
                // Never let a compiler warning slip by unnoticed — surface issues
                // (unused values, deprecations, concurrency) at build time.
                .unsafeFlags(["-warnings-as-errors"])
            ]
        ),
        .testTarget(
            name: "SonarTests",
            dependencies: ["Sonar"],
            path: "Tests/SonarTests"
        )
    ]
)
