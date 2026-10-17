// swift-tools-version: 5.9
import PackageDescription
let package = Package(
    name: "PhotoBridge", platforms: [.macOS(.v13), .iOS(.v16)],
    products: [.library(name: "PhotoBridgeCore", targets: ["PhotoBridgeCore"]),
               .executable(name: "PhotoBridgeMac", targets: ["PhotoBridgeMac"]),
               .executable(name: "CoreChecks", targets: ["CoreChecks"])],
    targets: [.target(name: "PhotoBridgeCore"),
              .executableTarget(name: "PhotoBridgeMac", dependencies: ["PhotoBridgeCore"]),
              .executableTarget(name: "CoreChecks", dependencies: ["PhotoBridgeCore"], path: "tests/CoreChecks"),
              .testTarget(name: "PhotoBridgeCoreTests", dependencies: ["PhotoBridgeCore"], path: "tests/PhotoBridgeCoreTests")])
