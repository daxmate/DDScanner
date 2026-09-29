// swift-tools-version: 6.0
// DDScannerDewarp —— 见 docs/architecture.md（依赖 DDScannerCore，只依赖其协议）。
import PackageDescription

let package = Package(
    name: "DDScannerDewarp",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "DDScannerDewarp", targets: ["DDScannerDewarp"]),
    ],
    dependencies: [
        .package(path: "../DDScannerCore"),
    ],
    targets: [
        .target(
            name: "DDScannerDewarp",
            dependencies: [.product(name: "DDScannerCore", package: "DDScannerCore")],
            path: "Sources/DDScannerDewarp"
        ),
    ],
    swiftLanguageModes: [.v5]
)
