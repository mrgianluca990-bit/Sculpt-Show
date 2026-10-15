// swift-tools-version: 5.9
import PackageDescription

var products: [Product] = [
    .library(name: "SculptShowCore", targets: ["SculptShowCore"])
]

var targets: [Target] = [
    .target(name: "SculptShowCore"),
    .testTarget(name: "SculptShowCoreTests", dependencies: ["SculptShowCore"])
]

#if os(macOS)
products.append(.executable(name: "SculptShow", targets: ["SculptShowApp"]))
targets.append(.executableTarget(name: "SculptShowApp", dependencies: ["SculptShowCore"]))
#endif

let package = Package(
    name: "SculptShow",
    platforms: [.macOS(.v13)],
    products: products,
    targets: targets
)
