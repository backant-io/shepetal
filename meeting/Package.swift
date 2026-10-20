// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "shepetal-meeting",
    platforms: [.macOS(.v14)],
    targets: [
        .target(name: "MeetingCore"),
        .target(name: "MeetingMac", dependencies: ["MeetingCore"]),
        .executableTarget(name: "shepetal-meeting", dependencies: ["MeetingCore", "MeetingMac"]),
        .testTarget(name: "MeetingCoreTests", dependencies: ["MeetingCore"]),
    ]
)
