// QuadEditingTests —— 四角拖拽微调几何（批 B2）的纯逻辑测试。
import CoreGraphics
import Testing
@testable import DDScannerCore

@Suite("QuadEditing · Corner")
struct QuadEditingCornerTests {
    @Test("adjacent 沿边相邻关系正确")
    func adjacency() {
        #expect(QuadEditing.Corner.topLeft.adjacent == (.topRight, .bottomLeft))
        #expect(QuadEditing.Corner.topRight.adjacent == (.bottomRight, .topLeft))
        #expect(QuadEditing.Corner.bottomRight.adjacent == (.bottomLeft, .topRight))
        #expect(QuadEditing.Corner.bottomLeft.adjacent == (.topLeft, .bottomRight))
    }

    @Test("replacing 只改目标角，其余角不变")
    func replacing() {
        let quad = DocumentQuad.fixture
        let moved = QuadEditing.Corner.topRight.replacing(CGPoint(x: 99, y: 21), in: quad)
        #expect(moved.topRight == CGPoint(x: 99, y: 21))
        #expect(moved.topLeft == quad.topLeft)
        #expect(moved.bottomRight == quad.bottomRight)
        #expect(moved.bottomLeft == quad.bottomLeft)
    }
}

@Suite("QuadEditing · AspectFitMapping")
struct QuadEditingMappingTests {
    private func close(_ a: CGPoint, _ b: CGPoint) -> Bool {
        abs(a.x - b.x) < 1e-6 && abs(a.y - b.y) < 1e-6
    }

    @Test("宽图在方框内左右贴边、上下留白")
    func horizontalLetterbox() {
        let mapping = QuadEditing.AspectFitMapping(
            imageSize: CGSize(width: 200, height: 100),
            displayRect: CGRect(x: 0, y: 0, width: 100, height: 100)
        )
        #expect(abs(mapping.scale - 0.5) < 1e-9)
        #expect(mapping.displayedSize == CGSize(width: 100, height: 50))
        #expect(mapping.contentOrigin == CGPoint(x: 0, y: 25))
        // 图片中心落在显示矩形中心。
        let center = mapping.viewPoint(forNormalized: CGPoint(x: 0.5, y: 0.5))
        #expect(close(center, CGPoint(x: 50, y: 50)))
    }

    @Test("高图在方框内上下贴边、左右留白")
    func verticalLetterbox() {
        let mapping = QuadEditing.AspectFitMapping(
            imageSize: CGSize(width: 100, height: 200),
            displayRect: CGRect(x: 0, y: 0, width: 100, height: 100)
        )
        #expect(abs(mapping.scale - 0.5) < 1e-9)
        #expect(mapping.contentOrigin == CGPoint(x: 25, y: 0))
        let center = mapping.viewPoint(forNormalized: CGPoint(x: 0.5, y: 0.5))
        #expect(close(center, CGPoint(x: 50, y: 50)))
    }

    @Test("非 4:3 显示框（5:4）也能正确映射")
    func nonStandardRect() {
        let mapping = QuadEditing.AspectFitMapping(
            imageSize: CGSize(width: 400, height: 300),
            displayRect: CGRect(x: 10, y: 20, width: 200, height: 160)
        )
        // 400:300 = 4:3，显示框 200:160 = 5:4；图更宽 → 上下留白。
        #expect(abs(mapping.scale - 0.5) < 1e-9)
        #expect(mapping.displayedSize == CGSize(width: 200, height: 150))
        #expect(mapping.contentOrigin == CGPoint(x: 10, y: 25))
        let center = mapping.viewPoint(forNormalized: CGPoint(x: 0.5, y: 0.5))
        #expect(close(center, CGPoint(x: 110, y: 100)))
    }

    @Test("视图 → 像素 roundtrip")
    func viewPixelRoundtrip() {
        let mapping = QuadEditing.AspectFitMapping(
            imageSize: CGSize(width: 300, height: 200),
            displayRect: CGRect(x: 0, y: 0, width: 90, height: 90)
        )
        for point in [
            CGPoint(x: 0, y: 0),
            CGPoint(x: 150, y: 100),
            CGPoint(x: 300, y: 200),
            CGPoint(x: 37, y: 89),
        ] {
            let view = mapping.viewPoint(forPixel: point)
            let back = mapping.pixelPoint(forView: view)
            #expect(close(back, point))
        }
    }

    @Test("归一化 ↔ 像素 roundtrip")
    func normalizedPixelRoundtrip() {
        let mapping = QuadEditing.AspectFitMapping(
            imageSize: CGSize(width: 300, height: 200),
            displayRect: CGRect(x: 0, y: 0, width: 90, height: 90)
        )
        for point in [
            CGPoint(x: 0, y: 0),
            CGPoint(x: 0.5, y: 0.5),
            CGPoint(x: 1, y: 1),
        ] {
            let pixel = mapping.pixelPoint(forNormalized: point)
            let back = mapping.normalizedPoint(forPixel: pixel)
            #expect(close(back, point))
        }
    }
}

@Suite("QuadEditing · 拖拽夹紧")
struct QuadEditingClampTests {
    private func close(_ a: CGPoint, _ b: CGPoint) -> Bool {
        abs(a.x - b.x) < 1e-6 && abs(a.y - b.y) < 1e-6
    }

    private var fullFrame: DocumentQuad {
        DocumentQuad(
            topLeft: CGPoint(x: 0, y: 0),
            topRight: CGPoint(x: 1, y: 0),
            bottomRight: CGPoint(x: 1, y: 1),
            bottomLeft: CGPoint(x: 0, y: 1)
        )
    }

    @Test("越界角被钳回图片边界")
    func clampsToBounds() {
        let imageSize = CGSize(width: 100, height: 100)
        let config = QuadEditing.ClampConfig(minimumAdjacentDistance: 0)
        let clamped = QuadEditing.clamp(
            fullFrame,
            moving: .topLeft,
            to: CGPoint(x: -0.5, y: -0.5),
            imageSize: imageSize,
            config: config
        )
        #expect(close(clamped.topLeft, CGPoint(x: 0, y: 0)))
    }

    @Test("拖近相邻角时被外推到最小距离")
    func enforcesMinDistance() {
        let imageSize = CGSize(width: 100, height: 100)
        let config = QuadEditing.ClampConfig(minimumAdjacentDistance: 10)
        let clamped = QuadEditing.clamp(
            fullFrame,
            moving: .topLeft,
            to: CGPoint(x: 0.98, y: 0),
            imageSize: imageSize,
            config: config
        )
        // 目标点距右上角仅 2px，被外推到距右上角 10px 处（像素 90 → 归一化 0.9）。
        #expect(close(clamped.topLeft, CGPoint(x: 0.9, y: 0)))
    }

    @Test("不拖动时夹紧为 no-op")
    func noopWhenUnchanged() {
        let imageSize = CGSize(width: 100, height: 100)
        let config = QuadEditing.ClampConfig(minimumAdjacentDistance: 10)
        let clamped = QuadEditing.clamp(
            fullFrame,
            moving: .topLeft,
            to: CGPoint(x: 0, y: 0),
            imageSize: imageSize,
            config: config
        )
        #expect(close(clamped.topLeft, CGPoint(x: 0, y: 0)))
        #expect(clamped == fullFrame)
    }

    @Test("最小距离为 0 时不产生外推")
    func zeroMinDistanceNoPush() {
        let imageSize = CGSize(width: 100, height: 100)
        let config = QuadEditing.ClampConfig(minimumAdjacentDistance: 0)
        let clamped = QuadEditing.clamp(
            fullFrame,
            moving: .topLeft,
            to: CGPoint(x: 0.5, y: 0.5),
            imageSize: imageSize,
            config: config
        )
        #expect(close(clamped.topLeft, CGPoint(x: 0.5, y: 0.5)))
    }
}

@Suite("QuadEditing · 合法性判定")
struct QuadEditingValidateTests {
    @Test("满幅四边形合法")
    func fullFrameValid() {
        let quad = DocumentQuad(
            topLeft: CGPoint(x: 0, y: 0),
            topRight: CGPoint(x: 1, y: 0),
            bottomRight: CGPoint(x: 1, y: 1),
            bottomLeft: CGPoint(x: 0, y: 1)
        )
        #expect(QuadEditing.validate(quad) == nil)
    }

    @Test("角点重合判退化")
    func degenerate() {
        let quad = DocumentQuad(
            topLeft: CGPoint(x: 0, y: 0),
            topRight: CGPoint(x: 1, y: 0),
            bottomRight: CGPoint(x: 1, y: 1),
            bottomLeft: CGPoint(x: 0, y: 0)
        )
        #expect(QuadEditing.validate(quad) == .degenerate)
    }

    @Test("自交四边形判非凸")
    func nonConvex() {
        let quad = DocumentQuad(
            topLeft: CGPoint(x: 0, y: 0),
            topRight: CGPoint(x: 1, y: 0),
            bottomRight: CGPoint(x: 0, y: 1),
            bottomLeft: CGPoint(x: 1, y: 1)
        )
        #expect(QuadEditing.validate(quad) == .nonConvex)
    }

    @Test("三点共线判非凸")
    func collinearNonConvex() {
        let quad = DocumentQuad(
            topLeft: CGPoint(x: 0, y: 0),
            topRight: CGPoint(x: 0.5, y: 0),
            bottomRight: CGPoint(x: 1, y: 0),
            bottomLeft: CGPoint(x: 0, y: 1)
        )
        #expect(QuadEditing.validate(quad) == .nonConvex)
    }

    @Test("面积过小判 areaTooSmall")
    func areaTooSmall() {
        let quad = DocumentQuad(
            topLeft: CGPoint(x: 0, y: 0),
            topRight: CGPoint(x: 0.1, y: 0),
            bottomRight: CGPoint(x: 0.1, y: 0.1),
            bottomLeft: CGPoint(x: 0, y: 0.1)
        )
        #expect(QuadEditing.validate(quad) == .areaTooSmall(minimumRatio: QuadEditing.defaultMinimumAreaRatio))
    }
}
