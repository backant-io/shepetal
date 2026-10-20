// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Shepetal",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "shepetal", targets: ["Shepetal"])],
    dependencies: [
        .package(url: "https://github.com/FluidInference/FluidAudio", exact: "0.17.7"),
    ],
    targets: [
        // Pure Swift: gesture state machine, model tiers, audio store, history, text rules.
        .target(name: "ShepetalCore", linkerSettings: [.linkedLibrary("sqlite3")]),
        // AppKit shell: menu bar, indicator, fn tap, capture, STT, insertion, permissions.
        .executableTarget(name: "Shepetal", dependencies: [
            "ShepetalCore",
            .product(name: "FluidAudio", package: "FluidAudio"),
        ]),
        .testTarget(name: "ShepetalCoreTests", dependencies: ["ShepetalCore"]),
    ],
    swiftLanguageModes: [.v5]
)
