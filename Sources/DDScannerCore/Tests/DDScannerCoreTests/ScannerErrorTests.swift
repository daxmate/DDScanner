// ScannerErrorTests —— Core 层错误描述（既有测试风格：@Suite + @Test）。
import Foundation
import Testing
@testable import DDScannerCore

@Suite("ScannerError")
struct ScannerErrorTests {
    @Test("exportFailed 描述点明导出失败与原因")
    func exportFailedDescription() {
        let error = ScannerError.exportFailed("目录不可写")
        #expect(error.description == "导出失败：目录不可写")
    }

    @Test("stageNotConfigured 描述点明阶段名")
    func stageNotConfiguredDescription() {
        #expect(ScannerError.stageNotConfigured("exporter").description == "管线阶段未装配：exporter")
    }

    @Test("invalidFrameSize 描述包含宽高")
    func invalidFrameSizeDescription() {
        #expect(ScannerError.invalidFrameSize(width: 3, height: 5).description == "非法帧尺寸：3×5")
    }
}
