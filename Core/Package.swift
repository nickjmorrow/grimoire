// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "GrimoireCore",
    platforms: [.macOS(.v15), .iOS(.v18)],
    products: [.library(name: "GrimoireCore", targets: ["GrimoireCore"])],
    dependencies: [.package(url: "https://github.com/groue/GRDB.swift", from: "7.0.0")],
    targets: [
        .target(name: "GrimoireCore", dependencies: [.product(name: "GRDB", package: "GRDB.swift")]),
        .testTarget(name: "GrimoireCoreTests", dependencies: ["GrimoireCore", .product(name: "GRDB", package: "GRDB.swift")]),
    ]
)
