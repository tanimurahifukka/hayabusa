// swift-tools-version: 5.10
import PackageDescription

// Absolute path to llama.cpp build artifacts
let llamaBuildDir = "\(Context.packageDirectory)/vendor/llama.cpp/build"

let package = Package(
    name: "Hayabusa",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(url: "https://github.com/hummingbird-project/hummingbird.git", from: "2.0.0"),
        // mlx-swift-lm is pinned to the commit that was resolved when the MLX backend
        // was last operational. The backend currently throws at startup pending an
        // API migration; updating this revision should happen as part of that work.
        .package(
            url: "https://github.com/ml-explore/mlx-swift-lm.git",
            revision: "52e999486e133dfb94a5c329befcb11eb52d908a"
        ),
    ],
    targets: [
        .target(
            name: "CLlama",
            path: "Sources/CLlama",
            linkerSettings: [
                .unsafeFlags([
                    "-L\(llamaBuildDir)/src",
                    "-L\(llamaBuildDir)/ggml/src",
                    "-L\(llamaBuildDir)/ggml/src/ggml-metal",
                    "-L\(llamaBuildDir)/ggml/src/ggml-blas",
                ]),
                .linkedLibrary("llama"),
                .linkedLibrary("ggml"),
                .linkedLibrary("ggml-base"),
                .linkedLibrary("ggml-metal"),
                .linkedLibrary("ggml-cpu"),
                .linkedLibrary("ggml-blas"),
                .linkedLibrary("c++"),
                .linkedFramework("Metal"),
                .linkedFramework("MetalKit"),
                .linkedFramework("MetalPerformanceShaders"),
                .linkedFramework("Foundation"),
                .linkedFramework("Accelerate"),
            ]
        ),
        .executableTarget(
            name: "Hayabusa",
            dependencies: [
                .product(name: "Hummingbird", package: "hummingbird"),
                .product(name: "MLXLLM", package: "mlx-swift-lm"),
                .product(name: "MLXLMCommon", package: "mlx-swift-lm"),
                "CLlama",
            ],
            path: "Sources/Hayabusa"
        ),
    ]
)
