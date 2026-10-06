// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "GrimoireUI",
    platforms: [.macOS(.v15), .iOS(.v18)],
    products: [.library(name: "GrimoireUI", targets: ["GrimoireUI"])],
    dependencies: [.package(path: "../Core")],
    targets: [
        .target(name: "GrimoireUI",
                dependencies: [.product(name: "GrimoireCore", package: "Core")],
                resources: [.process("Resources")],
                swiftSettings: [.swiftLanguageMode(.v5)]),
        .testTarget(name: "GrimoireUITests", dependencies: ["GrimoireUI"], swiftSettings: [.swiftLanguageMode(.v5)]),
    ]
)
