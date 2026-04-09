// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "SwiftAgent",
    platforms: [
        .iOS(.v17),
        .macOS(.v14)
    ],
    products: [
        .library(name: "SwiftAgent", targets: ["SwiftAgent"]),
    ],
    dependencies: [
        // LLM inference via llama.cpp
        .package(url: "https://github.com/mattt/llama.swift", from: "2.8665.0"),
    ],
    targets: [
        .target(
            name: "SwiftAgent",
            dependencies: [
                .product(name: "LlamaSwift", package: "llama.swift"),
            ],
            path: "Sources/SwiftAgent"
        ),
        .testTarget(
            name: "SwiftAgentTests",
            dependencies: ["SwiftAgent"],
            path: "Tests/SwiftAgentTests"
        ),
    ]
)
