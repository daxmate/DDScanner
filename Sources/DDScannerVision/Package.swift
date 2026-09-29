// swift-tools-version: 6.0
// DDScannerVision —— 见 docs/architecture.md（依赖 DDScannerCore，只依赖其协议）。
import PackageDescription

let package = Package(
    name: "DDScannerVision",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "DDScannerVision", targets: ["DDScannerVision"]),
    ],
    dependencies: [
        .package(path: "../DDScannerCore"),
    ],
    targets: [
        .target(
            name: "DDScannerVision",
            dependencies: [.product(name: "DDScannerCore", package: "DDScannerCore")],
            path: "Sources/DDScannerVision"
        ),
    ],
    swiftLanguageModes: [.v5]
)
