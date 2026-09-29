// swift-tools-version: 6.0
// 契约测试包：可在 macOS 上 `swift test --package-path Tests` 直接跑（无需模拟器）。
import PackageDescription

let package = Package(
    name: "DDScannerContractTests",
    platforms: [.macOS(.v14)],
    targets: [
        .testTarget(name: "ContractTests", path: "ContractTests"),
    ],
    swiftLanguageModes: [.v5]
)
