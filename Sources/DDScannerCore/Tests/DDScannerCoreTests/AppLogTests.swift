// 日志出口测试（占位，见 docs/logging.md）。
import Testing
@testable import DDScannerCore

@Suite("AppLog")
struct AppLogTests {
    @Test("自定义 sink 收到分级前缀与分类")
    func sinkReceivesLine() {
        let sink = CapturingSink()
        AppLog.addSink(sink)
        AppLog.warning("检测失败", category: .vision)
        #expect(sink.lines.contains { $0.contains("[vision][warning] 检测失败") })
    }

    @Test("级别可比较")
    func levelOrdering() {
        #expect(LogLevel.debug < LogLevel.info)
        #expect(LogLevel.warning < LogLevel.error)
    }

    @Test("分类集合齐全")
    func categories() {
        #expect(LogCategory.allCases.contains(.pipeline))
        #expect(LogCategory.allCases.count == 7)
    }
}
