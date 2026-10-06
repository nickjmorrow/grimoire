// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "grim",
    platforms: [.macOS(.v15)],
    dependencies: [
        .package(path: "../Core"),
        .package(url: "https://github.com/apple/swift-argument-parser", from: "1.5.0"),
    ],
    targets: [
        .executableTarget(name: "grim", dependencies: [
            .product(name: "GrimoireCore", package: "Core"),
            .product(name: "ArgumentParser", package: "swift-argument-parser"),
        ]),
        .executableTarget(name: "grim-sync", dependencies: [
            .product(name: "GrimoireCore", package: "Core"),
            .product(name: "ArgumentParser", package: "swift-argument-parser"),
        ]),
        .testTarget(name: "grimTests", dependencies: ["grim"]),
    ]
)
