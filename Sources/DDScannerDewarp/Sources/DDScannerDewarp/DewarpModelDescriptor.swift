// DewarpModelDescriptor —— 去畸变模型元信息（占位，见 docs/model-supply-chain.md）。
import DDScannerCore
import Foundation

/// 模型产物描述：转换链 Paddle → ONNX → Core ML，产物与脚本必须成对（可复现）。
public struct DewarpModelDescriptor: Equatable, Sendable {
    public let name: String
    public let version: String
    public let bundleResource: String
    public let license: String
    public let upstream: String

    public init(name: String, version: String, bundleResource: String, license: String, upstream: String) {
        self.name = name
        self.version = version
        self.bundleResource = bundleResource
        self.license = license
        self.upstream = upstream
    }

    /// UVDoc 权重与代码均为 Apache-2.0（原版仓库 MIT），见 NOTICE.md。
    public static let uvDoc = DewarpModelDescriptor(
        name: "UVDoc",
        version: "0.0.1",
        bundleResource: "UVDoc.mlpackage",
        license: "Apache-2.0",
        upstream: "https://github.com/tanguymagne/UVDoc"
    )
}
