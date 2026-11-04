// swift-tools-version: 6.0
import PackageDescription

let package = Package(
  name: "AgentGateStudio",
  platforms: [.macOS(.v14)],
  products: [
    .executable(name: "AgentGateStudio", targets: ["AgentGateStudio"])
  ],
  targets: [
    // Model manager logic, free of UI so it is unit-tested directly.
    .target(name: "AgentGateCore", resources: [.copy("Resources/catalog.json")]),
    .executableTarget(name: "AgentGateStudio", dependencies: ["AgentGateCore"]),
    .testTarget(name: "AgentGateCoreTests", dependencies: ["AgentGateCore"]),
  ]
)
