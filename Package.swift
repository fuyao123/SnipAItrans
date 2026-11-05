// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "SnipAItrans",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(name: "SnipAItrans", targets: ["GPTTranslator"])
    ],
    targets: [
        .executableTarget(
            name: "GPTTranslator",
            path: "Sources/GPTTranslator"
        )
    ]
)
