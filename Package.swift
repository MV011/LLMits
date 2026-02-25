// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "LLMits",
    platforms: [
        .macOS(.v14)
    ],
    targets: [
        .executableTarget(
            name: "LLMits",
            path: "Sources/Perihelion",
            resources: [
                .process("Resources")
            ],
            swiftSettings: [
                .swiftLanguageMode(.v5)
            ]
        )
    ]
)
