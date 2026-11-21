// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "DuplexVoiceKit",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "DuplexVoiceKit", targets: ["DuplexVoiceKit"]),
        .library(name: "DuplexVoiceApple", targets: ["DuplexVoiceApple"]),
        .library(name: "DuplexVoiceLiveKit", targets: ["DuplexVoiceLiveKit"]),
    ],
    dependencies: [
        .package(url: "https://github.com/livekit/client-sdk-swift.git", from: "2.19.0"),
    ],
    targets: [
        .target(name: "DuplexVoiceKit"),
        .target(name: "DuplexVoiceApple", dependencies: ["DuplexVoiceKit"]),
        .target(name: "DuplexVoiceLiveKit", dependencies: [
            "DuplexVoiceKit", .product(name: "LiveKit", package: "client-sdk-swift")
        ]),
        .testTarget(name: "DuplexVoiceKitTests", dependencies: ["DuplexVoiceKit"]),
    ]
)
