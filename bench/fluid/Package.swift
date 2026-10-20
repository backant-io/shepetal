// swift-tools-version: 5.10
// Parakeet TDT 0.6B v3 through FluidAudio (CoreML / ANE) for bench.py. Built by run.sh into ../.cache/fluid-build.
import PackageDescription

let package = Package(
    name: "fluid-bench",
    platforms: [.macOS(.v14)],
    dependencies: [.package(url: "https://github.com/FluidInference/FluidAudio", exact: "0.17.7")],
    targets: [.executableTarget(name: "fluid-bench", dependencies: [.product(name: "FluidAudio", package: "FluidAudio")])]
)
