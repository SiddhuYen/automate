// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Automate",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "Automate", targets: ["Automate"]),
        .library(name: "AutomateCore", targets: ["AutomateCore"]),
    ],
    targets: [
        // Foundation-only engine: Claude CLI runner, loop files, scheduling, storage.
        .target(name: "AutomateCore"),
        // SwiftUI / AppKit app.
        .executableTarget(name: "Automate", dependencies: ["AutomateCore"]),
        .testTarget(name: "AutomateCoreTests", dependencies: ["AutomateCore"]),
    ]
)
