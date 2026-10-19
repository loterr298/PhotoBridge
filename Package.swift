// swift-tools-version: 5.9
import PackageDescription
let package = Package(
    name: "PhotoBridge", platforms: [.macOS(.v13), .iOS(.v16)],
    products: [.library(name: "PhotoBridgeCore", targets: ["PhotoBridgeCore"]),
               .executable(name: "PhotoBridgeMac", targets: ["PhotoBridgeMac"]),
               .executable(name: "CoreChecks", targets: ["CoreChecks"]),
               .executable(name: "StagingChecks", targets: ["StagingChecks"]),
               .executable(name: "RecoveryChecks", targets: ["RecoveryChecks"])],
    targets: [.target(name: "PhotoBridgeCore"),
              .executableTarget(name: "PhotoBridgeMac", dependencies: ["PhotoBridgeCore"]),
              .executableTarget(name: "CoreChecks", dependencies: ["PhotoBridgeCore"], path: "tests/CoreChecks"),
              .executableTarget(name: "StagingChecks", dependencies: ["PhotoBridgeCore"], path: "tests/StagingChecks"),
              .executableTarget(name: "RecoveryChecks", dependencies: ["PhotoBridgeCore"], path: "tests/RecoveryChecks"),
              .testTarget(name: "PhotoBridgeCoreTests", dependencies: ["PhotoBridgeCore"], path: "tests/PhotoBridgeCoreTests")])
