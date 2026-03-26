// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "HayabusaApp",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(url: "https://github.com/sparkle-project/Sparkle.git", from: "2.6.0"),
    ],
    targets: [
        .executableTarget(
            name: "HayabusaApp",
            dependencies: [
                .product(name: "Sparkle", package: "Sparkle"),
            ],
            path: "Sources/HayabusaApp",
            resources: [
                .process("../../Resources"),
            ]
        ),
    ]
)
