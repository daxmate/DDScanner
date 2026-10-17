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
        // 位图导出行为测试（本机 macOS 可跑，无模拟器）：JPEG/PDF 落盘、页面尺寸、唯一目录、失败清理。
        .testTarget(
            name: "DDScannerExportTests",
            dependencies: ["DDScannerExport"],
            path: "Tests/DDScannerExportTests"
        ),
    ],
    swiftLanguageModes: [.v5]
)
