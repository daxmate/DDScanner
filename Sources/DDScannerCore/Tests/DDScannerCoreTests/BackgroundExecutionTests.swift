// 后台执行等价性：证明自测页依赖的纯逻辑在**非主线程**上调用结果一致；
// 以及 FloatImage → CGImage 渲染往返（平台层与 Vision 成像共用这一份实现）。
import CoreGraphics
import Foundation
import Testing
@testable import DDScannerCore

@Suite("后台执行等价性")
struct BackgroundExecutionTests {
    private static let size = CGSize(width: 340, height: 260)

    private static var quad: DocumentQuad {
        DocumentQuad(
            topLeft: CGPoint(x: 0.18, y: 0.14),
            topRight: CGPoint(x: 0.88, y: 0.25),
            bottomRight: CGPoint(x: 0.82, y: 0.86),
            bottomLeft: CGPoint(x: 0.12, y: 0.75)
        )
    }

    /// 构造一张有结构的图（渐变 + 条纹），避免全常量导致等价性断言退化成恒等。
    private static func fixtureImage() -> FloatImage {
        let width = 340
        let height = 260
        var values = [Float](repeating: 0, count: width * height * 3)
        let plane = width * height
        for y in 0 ..< height {
            for x in 0 ..< width {
                let index = y * width + x
                let stripe: Float = ((x / 7) % 2 == 0) ? 0.15 : 0.0
                values[index] = min(Float(x) / Float(width) + stripe, 1)
                values[plane + index] = min(Float(y) / Float(height), 1)
                values[2 * plane + index] = ((x + y) % 11 == 0) ? 0.9 : 0.2
            }
        }
        return FloatImage(width: width, height: height, channels: 3, values: values)
    }

    @Test("rectify 在后台线程执行：结果与主线程逐点完全相同")
    func rectifyOffMainThreadMatches() async throws {
        let source = Self.fixtureImage()
        let quad = Self.quad
        // 参照值在**主线程**上算（MainActor 的执行器就是主线程）。
        let reference = try #require(await MainActor.run { try? DocumentRectifier.rectify(source, quad: quad) })

        let (offThread, ranOffMain) = await Task.detached(priority: .userInitiated) {
            (try? DocumentRectifier.rectify(source, quad: quad), !Thread.isMainThread)
        }.value

        #expect(ranOffMain, "detached 任务必须不在主线程执行，否则本测试跟不住线程偏差")
        #expect(offThread == reference, "后台执行与主线程结果必须逐点一致")
    }

    @Test("FrontEndPlanner 决策在后台线程执行：与主线程一致")
    func plannerOffMainThreadMatches() async {
        let detection = DocumentDetection(quad: Self.quad, confidence: 0.77)
        let reference = await MainActor.run { FrontEndPlanner.decide(detection: detection, sourceSize: Self.size) }
        let (offThread, ranOffMain) = await Task.detached {
            (FrontEndPlanner.decide(detection: detection, sourceSize: Self.size), !Thread.isMainThread)
        }.value
        #expect(ranOffMain)
        #expect(offThread == reference)
    }

    @Test("并发多次调用结果稳定（无共享可变状态）")
    func concurrentCallsAreStable() async {
        let source = Self.fixtureImage()
        let quad = Self.quad
        let reference = try? DocumentRectifier.rectify(source, quad: quad)
        let results = await withTaskGroup(of: FloatImage?.self) { group in
            for _ in 0 ..< 4 {
                group.addTask { try? DocumentRectifier.rectify(source, quad: quad) }
            }
            var collected = [FloatImage?]()
            for await result in group { collected.append(result) }
            return collected
        }
        #expect(results.count == 4)
        for result in results {
            #expect(result == reference)
        }
    }

    @Test("FloatImage → CGImage → FloatImage 往返在量化误差内一致")
    func makeCGImageRoundTrip() throws {
        let source = Self.fixtureImage()
        let image = try #require(FloatImageConverter.makeCGImage(from: source))
        #expect(image.width == source.width && image.height == source.height)
        let back = try FloatImageConverter.rgb(from: image, width: source.width, height: source.height)
        for index in stride(from: 0, to: source.values.count, by: 97) {
            #expect(abs(back.values[index] - source.values[index]) <= 1.0 / 255 + 1e-6)
        }
    }
}
