// swift-tools-version: 6.0
// DDScannerExport —— 见 docs/architecture.md（依赖 DDScannerCore，只依赖其协议）。
import PackageDescription

let package = Package(
    name: "DDScannerExport",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "DDScannerExport", targets: ["DDScannerExport"]),
    ],
    dependencies: [
        .package(path: "../DDScannerCore"),
    ],
    targets: [
        .target(
            name: "DDScannerExport",
            dependencies: [.product(name: "DDScannerCore", package: "DDScannerCore")],
            path: "Sources/DDScannerExport"
        ),
    ],
    swiftLanguageModes: [.v5]
)
