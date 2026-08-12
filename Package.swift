// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "LLMits",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "LLMits", targets: ["LLMits"])
    ],
    targets: [
        .target(
            name: "LLMitsCore",
            path: "Sources/LLMits",
            resources: [
                .process("Resources")
            ],
            swiftSettings: [
                .swiftLanguageMode(.v5)
            ]
        ),
        .executableTarget(
            name: "LLMits",
            dependencies: ["LLMitsCore"],
            path: "Sources/LLMitsApp",
            swiftSettings: [
                .swiftLanguageMode(.v5)
            ]
        ),
        .executableTarget(
            name: "LLMitsCheck",
            dependencies: ["LLMitsCore"],
            path: "Tests/LLMitsCheck",
            swiftSettings: [
                .swiftLanguageMode(.v5)
            ]
        )
    ]
)
