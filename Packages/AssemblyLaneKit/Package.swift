// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "AssemblyLaneKit",
    platforms: [
        .iOS("26.0"),
        .macOS(.v15),
    ],
    products: [
        .library(name: "AssemblyLaneKit", targets: ["AssemblyLaneKit"]),
    ],
    targets: [
        .target(name: "AssemblyLaneKit"),
        .testTarget(name: "AssemblyLaneKitTests", dependencies: ["AssemblyLaneKit"]),
    ]
)
