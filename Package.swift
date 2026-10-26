// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "AudayBridge",
    platforms: [.macOS(.v13)],
    products: [.library(name: "AudayBridgeCore", targets: ["AudayBridgeCore"])],
    targets: [
        .target(name: "AudayBridgeCore", path: "AudayBridge",
                exclude: ["App.swift", "ContentView.swift", "Info.plist"]),
        .testTarget(name: "AudayBridgeTests", dependencies: ["AudayBridgeCore"], path: "Tests")
    ]
)
