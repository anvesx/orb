// swift-tools-version: 6.0
import PackageDescription

// OrbKit: no UI and no WebRTC (models, the agent service client, context, the call state machine, the app model).
// OrbVoice: the LiveKit call behind OrbKit's VoiceTransport. OrbUI: SwiftUI views; it reads OrbKit only.
// OrbApp: windows, menu bar, shortcuts, and the wiring. OrbProbe: a command-line call, to test the voice path alone.
let package = Package(
    name: "orb",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "orb", targets: ["OrbApp"]),
        .executable(name: "orb-probe", targets: ["OrbProbe"]),
    ],
    dependencies: [
        .package(url: "https://github.com/livekit/client-sdk-swift", exact: "2.19.0"),
        .package(url: "https://github.com/sindresorhus/KeyboardShortcuts", exact: "1.10.0"),
    ],
    targets: [
        .target(name: "OrbKit"),
        .target(name: "OrbVoice", dependencies: ["OrbKit", .product(name: "LiveKit", package: "client-sdk-swift")]),
        .target(name: "OrbUI", dependencies: ["OrbKit"]),
        .executableTarget(name: "OrbApp", dependencies: ["OrbKit", "OrbVoice", "OrbUI", "KeyboardShortcuts"]),
        .executableTarget(name: "OrbProbe", dependencies: ["OrbKit", "OrbVoice"]),
        .testTarget(name: "OrbKitTests", dependencies: ["OrbKit"]),
    ]
)
