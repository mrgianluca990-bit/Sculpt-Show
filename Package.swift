// swift-tools-version: 5.9
import PackageDescription

var products: [Product] = [
    .library(name: "SculptShowCore", targets: ["SculptShowCore"])
]

var targets: [Target] = [
    .target(name: "SculptShowCore", dependencies: ["SculptLTCCore"]),
    .target(name: "SculptLTCCore", publicHeadersPath: "include", linkerSettings: [.linkedLibrary("m")]),
    .testTarget(name: "SculptShowCoreTests", dependencies: ["SculptShowCore", "SculptLTCCore"])
]

#if os(macOS)
products.append(.executable(name: "SculptShow", targets: ["SculptShowApp"]))
targets.append(.executableTarget(name: "SculptShowApp", dependencies: ["SculptShowCore", "SculptLTCCore"], exclude: ["TimecodeGenerator.swift"]))
#endif

let package = Package(
    name: "SculptShow",
    platforms: [.macOS(.v13)],
    products: products,
    targets: targets
)
