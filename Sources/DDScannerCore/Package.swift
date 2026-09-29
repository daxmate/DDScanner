// swift-tools-version: 6.0
// DDScannerCore —— 平台无关纯逻辑层（见 docs/architecture.md）。
// 只允许 import Foundation / CoreGraphics / Accelerate；禁 UIKit / SwiftUI / Vision / CoreML。
import PackageDescription

let package = Package(
    name: "DDScannerCore",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "DDScannerCore", targets: ["DDScannerCore"]),
    ],
    targets: [
        .target(name: "DDScannerCore", path: "Sources/DDScannerCore"),
        .testTarget(name: "DDScannerCoreTests", dependencies: ["DDScannerCore"], path: "Tests/DDScannerCoreTests"),
    ],
    swiftLanguageModes: [.v5]
)
