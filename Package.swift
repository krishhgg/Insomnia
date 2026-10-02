// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "Insomnia",
    platforms: [
        .macOS(.v26),
    ],
    targets: [
        .executableTarget(
            name: "Insomnia",
            path: "Sources/Insomnia",
            swiftSettings: [
                .swiftLanguageMode(.v6),
            ]
        ),
        // Test-only C target. Its constructor points INSOMNIA_HOME at a temp
        // directory when the test bundle loads, before any test can log.
        .target(
            name: "InsomniaTestHome",
            path: "Tests/InsomniaTestHome"
        ),
        .testTarget(
            name: "InsomniaTests",
            dependencies: ["Insomnia", "InsomniaTestHome"],
            path: "Tests/InsomniaTests",
            swiftSettings: [
                .swiftLanguageMode(.v6),
            ]
        ),
    ]
)
