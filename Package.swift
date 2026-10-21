// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Shepetal",
    platforms: [.macOS("14.4")],  // meeting capture needs Core Audio process taps (14.4)
    products: [.executable(name: "shepetal", targets: ["Shepetal"])],
    dependencies: [
        .package(url: "https://github.com/FluidInference/FluidAudio", exact: "0.17.7"),
        .package(path: "meeting"),
        .package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.10.0"),  // auto-updates (docs/install-and-update.md)
    ],
    targets: [
        // Pure Swift: gesture state machine, model tiers, audio store, history, text rules.
        .target(name: "ShepetalCore", linkerSettings: [.linkedLibrary("sqlite3")]),
        // Local cleanup model: llama.cpp (Metal) behind ShepetalCore's CleanupModel.
        .binaryTarget(name: "llama",
                      url: "https://github.com/ggml-org/llama.cpp/releases/download/b11450/llama-b11450-xcframework.zip",
                      checksum: "a435ce4d51fd3cb17a3aca04f378dcc8391d2d220dc69771e11b266df27015fa"),
        .target(name: "ShepetalCleanup", dependencies: ["ShepetalCore", "llama"]),
        // AppKit shell: menu bar, indicator, fn tap, capture, STT, insertion, permissions.
        .executableTarget(name: "Shepetal", dependencies: [
            "ShepetalCore",
            "ShepetalCleanup",
            "ShepetalSummary",
            .product(name: "FluidAudio", package: "FluidAudio"),
            .product(name: "MeetingCore", package: "meeting"),
            .product(name: "MeetingMac", package: "meeting"),
            .product(name: "Sparkle", package: "Sparkle"),
        ]),
        // bench/cleanup/run.sh: scores cleanup models on bench/cleanup/fixtures.
        .executableTarget(name: "cleanup-bench", dependencies: ["ShepetalCleanup"], path: "bench/cleanup/Sources"),
        // Meeting summarizer: not an LLM (rule 6).
        .target(name: "ShepetalSummary", dependencies: ["ShepetalCore"], resources: [.copy("actions_model.json")]),
        .testTarget(name: "ShepetalCoreTests", dependencies: ["ShepetalCore"]),
        .testTarget(name: "ShepetalTests", dependencies: ["Shepetal"]),
        .testTarget(name: "ShepetalSummaryTests", dependencies: ["ShepetalSummary"]),
        // Runs the real cleanup model when SHEPETAL_CLEANUP_MODEL names a GGUF; skipped otherwise.
        .testTarget(name: "ShepetalCleanupTests", dependencies: ["ShepetalCleanup"]),
    ],
    swiftLanguageModes: [.v5]
)
