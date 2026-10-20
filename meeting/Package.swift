// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "shepetal-meeting",
    platforms: [.macOS("14.4")],
    targets: [
        .target(name: "MeetingCore"),
        .target(name: "MeetingMac", dependencies: ["MeetingCore"]),
        .executableTarget(name: "shepetal-meeting", dependencies: ["MeetingCore", "MeetingMac"]),
        .testTarget(name: "MeetingCoreTests", dependencies: ["MeetingCore"]),
        .testTarget(name: "MeetingMacTests", dependencies: ["MeetingMac"]),
    ]
)
