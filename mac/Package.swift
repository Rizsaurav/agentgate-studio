// swift-tools-version: 6.0
import PackageDescription

let package = Package(
  name: "AgentGateStudio",
  platforms: [.macOS(.v14)],
  products: [
    .executable(name: "AgentGateStudio", targets: ["AgentGateStudio"])
  ],
  dependencies: [
    // Terminal emulator for the in-app terminal (MIT). Pinned to an exact release.
    .package(url: "https://github.com/migueldeicaza/SwiftTerm.git", exact: "1.99.0"),
  ],
  targets: [
    // Model manager logic, free of UI so it is unit-tested directly.
    .target(name: "AgentGateCore", resources: [.copy("Resources/catalog.json")]),
    .executableTarget(
      name: "AgentGateStudio",
      dependencies: ["AgentGateCore", .product(name: "SwiftTerm", package: "SwiftTerm")]),
    .testTarget(name: "AgentGateCoreTests", dependencies: ["AgentGateCore"]),
  ]
)
