// 管线编排测试（占位，见 docs/architecture.md）。
import Foundation
import Testing
@testable import DDScannerCore

@Suite("ScanPipeline")
struct ScanPipelineTests {
    private func pipeline(
        detector: DocumentDetecting = FixedDetector(quad: .fixture),
        dewarp: PageDewarping? = nil,
        exporter: PageExporting? = nil
    ) -> ScanPipeline {
        ScanPipeline(detector: detector, corrector: IdentityCorrector(), dewarp: dewarp, exporter: exporter)
    }

    @Test("无去畸变后端时回落平面网格")
    func flatFallback() throws {
        let frame = ScanFrame(identifier: "f1", width: 100, height: 200)
        let page = try pipeline().process(frame)
        #expect(page.identifier == "f1")
        #expect(page.samplingGrid.columns == 64)
        #expect(page.samplingGrid.points.count == 64 * 64)
    }

    @Test("装配去畸变后端时使用其网格")
    func dewarpPath() throws {
        let frame = ScanFrame(identifier: "f2", width: 100, height: 200)
        let page = try pipeline(dewarp: FixedDewarper()).process(frame)
        #expect(page.quad == .fixture)
    }

    @Test("非法帧尺寸报错")
    func invalidFrame() {
        let frame = ScanFrame(identifier: "bad", width: 0, height: 10)
        #expect(throws: ScannerError.invalidFrameSize(width: 0, height: 10)) {
            try pipeline().process(frame)
        }
    }

    @Test("检测失败时向上抛错")
    func detectFailure() {
        let frame = ScanFrame(identifier: "f3", width: 100, height: 200)
        #expect(throws: ScannerError.documentNotFound) {
            try pipeline(detector: FailingDetector()).process(frame)
        }
    }

    @Test("未装配 exporter 却要求导出时报错")
    func missingExporter() {
        let frame = ScanFrame(identifier: "f4", width: 100, height: 200)
        #expect(throws: ScannerError.stageNotConfigured("exporter")) {
            try pipeline().process(frame, destination: URL(fileURLWithPath: "/tmp/page.pdf"))
        }
    }

    @Test("装配 exporter 后导出被调用一次")
    func exportPath() throws {
        let exporter = RecordingExporter()
        let frame = ScanFrame(identifier: "f5", width: 100, height: 200)
        let url = URL(fileURLWithPath: "/tmp/page.pdf")
        _ = try pipeline(exporter: exporter).process(frame, destination: url)
        #expect(exporter.exported == [url])
    }
}
