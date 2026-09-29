// DewarpModelDescriptor —— 去畸变模型元信息（见 docs/model-supply-chain.md、Models/README.md）。
import DDScannerCore
import Foundation

/// 模型产物描述：转换链为「原版 PyTorch → torchscript trace → coremltools」，
/// 产物与脚本必须成对（可复现）——脚本 `Tools/ModelConvert/convert_uvdoc.py`。
public struct DewarpModelDescriptor: Equatable, Sendable {
    public let name: String
    public let version: String
    /// bundle 内资源基名（不含扩展名；加载时先找 `.mlmodelc` 再找 `.mlpackage`）。
    public let bundleResource: String
    public let license: String
    public let upstream: String
    /// 模型固定输入尺寸。
    public let inputWidth: Int
    public let inputHeight: Int
    /// 输入 feature 名（RGB，Float32，[0,1]）。
    public let inputName: String
    /// 采样网格输出 feature 名（`1×2×rows×columns`）。
    public let gridOutputName: String
    /// 网格输出分辨率。
    public let gridColumns: Int
    public let gridRows: Int

    public init(
        name: String,
        version: String,
        bundleResource: String,
        license: String,
        upstream: String,
        inputWidth: Int,
        inputHeight: Int,
        inputName: String = "image",
        gridOutputName: String = "point_positions2D",
        gridColumns: Int,
        gridRows: Int
    ) {
        self.name = name
        self.version = version
        self.bundleResource = bundleResource
        self.license = license
        self.upstream = upstream
        self.inputWidth = inputWidth
        self.inputHeight = inputHeight
        self.inputName = inputName
        self.gridOutputName = gridOutputName
        self.gridColumns = gridColumns
        self.gridRows = gridRows
    }

    /// UVDoc（原版 PyTorch 仓库，MIT）的 FP16 网格模型。
    /// 数值与许可依据：`Models/README.md`（权重 sha256 + MIT 归属 + 论文引用）。
    public static let uvDoc = DewarpModelDescriptor(
        name: "UVDoc",
        version: "1.0.0",
        bundleResource: "UVDocGrid_fp16",
        license: "MIT",
        upstream: "https://github.com/tanguymagne/UVDoc",
        inputWidth: 488,
        inputHeight: 712,
        gridColumns: 31,
        gridRows: 45
    )
}
