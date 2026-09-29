// CoreMLDewarpBackend 行为测试（本机 macOS `swift test` 可跑，无模拟器）。
//
// 覆盖两件必须成立的事：
//   ① 降级：模型缺失时**抛错而不是崩**（组合根据此把后端置 nil）；
//   ② 契约：仓库内的真实产物（`Models/UVDocGrid_fp16.mlpackage`）能装载并输出 45×31 网格，
//      且该网格可被 `GridResampler` 重采样（模型与重采样的接口对齐）。
import DDScannerCore
import DDScannerDewarp
import Foundation
import Testing

@Suite("CoreMLDewarpBackend")
struct CoreMLDewarpBackendTests {
    /// 模型产物路径：本文件 → Tests/DDScannerDewarpTests → Tests → DDScannerDewarp → Sources → 仓库根。
    private static var artifactURL: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Models/UVDocGrid_fp16.mlpackage")
    }

    private static func loadedBackend() throws -> CoreMLDewarpBackend {
        try CoreMLDewarpBackend(modelURL: artifactURL)
    }

    /// 合成一张有梯度的 RGB 图（避免全零输入掩盖网格退化）。
    private static func sampleImage() -> FloatImage {
        let width = DewarpModelDescriptor.uvDoc.inputWidth
        let height = DewarpModelDescriptor.uvDoc.inputHeight
        var values = [Float](repeating: 0, count: width * height * 3)
        let plane = width * height
        for y in 0 ..< height {
            for x in 0 ..< width {
                let index = y * width + x
                values[index] = Float(x) / Float(width)
                values[plane + index] = Float(y) / Float(height)
                values[2 * plane + index] = 0.5
            }
        }
        return FloatImage(width: width, height: height, channels: 3, values: values)
    }

    @Test("模型缺失时抛 modelUnavailable（可降级，不崩）")
    func missingModelFailsGracefully() {
        do {
            _ = try CoreMLDewarpBackend(bundle: Bundle.main)
            Issue.record("bundle 内没有模型，装载应当失败")
        } catch let error as ScannerError {
            guard case let .modelUnavailable(reason) = error else {
                Issue.record("错误类型不符：\(error)")
                return
            }
            #expect(reason.contains("UVDocGrid_fp16"), "错误信息应点名缺失的资源：\(reason)")
        } catch {
            Issue.record("错误类型不符：\(error)")
        }
    }

    @Test("仓库内产物存在且能装载")
    func artifactLoads() throws {
        #expect(FileManager.default.fileExists(atPath: Self.artifactURL.path), "产物必须入库：\(Self.artifactURL.path)")
        let backend = try Self.loadedBackend()
        #expect(backend.descriptor.gridColumns == 31)
        #expect(backend.descriptor.gridRows == 45)
    }

    @Test("真实产物推理 → 45×31 网格，坐标有限且在合理范围内")
    func predictsGridOnRealArtifact() throws {
        let backend = try Self.loadedBackend()
        let grid = try backend.predictGrid(for: Self.sampleImage())
        #expect(grid.columns == 31)
        #expect(grid.rows == 45)
        #expect(grid.xValues.count == 31 * 45)
        let all = grid.xValues + grid.yValues
        let allValuesAreFinite = all.allSatisfy(\.isFinite)
        #expect(allValuesAreFinite, "网格里不应出现 NaN / inf")
        let maximum = all.map(abs).max() ?? .infinity
        #expect(maximum <= 2, "归一化网格坐标应落在 [-1, 1] 附近，实测最大绝对值 \(maximum)")
    }

    @Test("输入尺寸不符 → 抛错（不崩、不静默出垃圾网格）")
    func rejectsWrongInputSize() throws {
        let backend = try Self.loadedBackend()
        let wrong = FloatImage(width: 8, height: 8, channels: 3, values: [Float](repeating: 0, count: 8 * 8 * 3))
        do {
            _ = try backend.predictGrid(for: wrong)
            Issue.record("尺寸不符时应当抛错")
        } catch let error as ScannerError {
            guard case .modelUnavailable = error else {
                Issue.record("错误类型不符：\(error)")
                return
            }
        }
    }

    @Test("输入通道数不符 → 抛错")
    func rejectsWrongChannelCount() throws {
        let backend = try Self.loadedBackend()
        let width = DewarpModelDescriptor.uvDoc.inputWidth
        let height = DewarpModelDescriptor.uvDoc.inputHeight
        let grayscale = FloatImage(width: width, height: height, channels: 1, values: [Float](repeating: 0, count: width * height))
        do {
            _ = try backend.predictGrid(for: grayscale)
            Issue.record("灰度输入应当抛错")
        } catch let error as ScannerError {
            guard case .modelUnavailable = error else {
                Issue.record("错误类型不符：\(error)")
                return
            }
        }
    }

    @Test("模型输出可直接接 GridResampler（模型 ↔ 重采样接口对齐）")
    func gridFeedsResampler() throws {
        let backend = try Self.loadedBackend()
        let image = Self.sampleImage()
        let grid = try backend.predictGrid(for: image)
        let output = GridResampler.resample(grid: grid, source: image, targetWidth: 120, targetHeight: 160)
        #expect(output.width == 120)
        #expect(output.height == 160)
        #expect(output.channels == 3)
        let outputIsFinite = output.values.allSatisfy(\.isFinite)
        let hasBrightPixel = output.values.contains { $0 > 0 }
        #expect(outputIsFinite)
        #expect(hasBrightPixel, "去畸变结果不应是全黑")
    }
}
