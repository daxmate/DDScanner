// 几何纯逻辑测试（占位，见 docs/architecture.md）。
import CoreGraphics
import Testing
@testable import DDScannerCore

@Suite("DocumentQuad")
struct DocumentQuadTests {
    @Test("归一化把角点映射到 0...1")
    func normalization() {
        let quad = DocumentQuad.fixture.normalized(in: CGSize(width: 100, height: 200))
        #expect(abs(quad.topLeft.x - 0.1) < 1e-9)
        #expect(abs(quad.bottomRight.y - 0.9) < 1e-9)
    }

    @Test("乱序四点恢复为 TL → TR → BR → BL")
    func ordering() {
        let points: [CGPoint] = [
            CGPoint(x: 90, y: 180),
            CGPoint(x: 10, y: 20),
            CGPoint(x: 90, y: 20),
            CGPoint(x: 10, y: 180),
        ]
        let quad = DocumentQuad.ordered(points)
        #expect(quad?.topLeft == CGPoint(x: 10, y: 20))
        #expect(quad?.bottomRight == CGPoint(x: 90, y: 180))
    }

    @Test("三点重合判定为退化")
    func degenerate() {
        let quad = DocumentQuad(
            topLeft: CGPoint(x: 0, y: 0),
            topRight: CGPoint(x: 0, y: 0),
            bottomRight: CGPoint(x: 10, y: 10),
            bottomLeft: CGPoint(x: 0, y: 10)
        )
        #expect(quad.isDegenerate)
    }

    @Test("非四点输入返回 nil")
    func wrongCount() {
        #expect(DocumentQuad.ordered([CGPoint(x: 1, y: 1)]) == nil)
    }
}

@Suite("Homography")
struct HomographyTests {
    @Test("轴对齐矩形映射到单位正方形")
    func mapsCorners() throws {
        let quad = DocumentQuad.fixture
        let homography = try #require(Homography(mapping: quad))
        let expectations: [(CGPoint, CGPoint)] = [
            (quad.topLeft, CGPoint(x: 0, y: 0)),
            (quad.topRight, CGPoint(x: 1, y: 0)),
            (quad.bottomRight, CGPoint(x: 1, y: 1)),
            (quad.bottomLeft, CGPoint(x: 0, y: 1)),
        ]
        for (source, target) in expectations {
            let mapped = homography.map(source)
            #expect(abs(mapped.x - target.x) < 1e-6)
            #expect(abs(mapped.y - target.y) < 1e-6)
        }
    }

    @Test("退化四边形求解失败")
    func singular() {
        let quad = DocumentQuad(
            topLeft: CGPoint(x: 0, y: 0),
            topRight: CGPoint(x: 0, y: 0),
            bottomRight: CGPoint(x: 0, y: 0),
            bottomLeft: CGPoint(x: 0, y: 0)
        )
        #expect(Homography(mapping: quad) == nil)
    }
}

@Suite("GridSampler")
struct GridSamplerTests {
    @Test("网格点数等于 columns × rows")
    func gridSize() {
        let grid = GridSampler.bilinear(within: .fixture, columns: 4, rows: 5)
        #expect(grid.points.count == 20)
        #expect(grid.point(column: 0, row: 0) == DocumentQuad.fixture.topLeft)
        #expect(grid.point(column: 3, row: 4) == DocumentQuad.fixture.bottomRight)
    }

    @Test("越界取点返回 nil")
    func outOfRange() {
        let grid = GridSampler.bilinear(within: .fixture, columns: 2, rows: 2)
        #expect(grid.point(column: 9, row: 0) == nil)
    }
}
