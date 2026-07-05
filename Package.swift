// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "TinyICS",
    platforms: [.iOS(.v16), .macOS(.v13), .watchOS(.v9), .tvOS(.v16)],
    products: [
        .library(name: "TinyICS", targets: ["TinyICS"])
    ],
    targets: [
        .target(name: "TinyICS"),
        .testTarget(name: "TinyICSTests", dependencies: ["TinyICS"])
    ]
)
