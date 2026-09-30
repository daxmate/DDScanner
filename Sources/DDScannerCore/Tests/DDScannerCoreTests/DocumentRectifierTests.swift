// DocumentRectifier / DocumentQuad 形状判定的纯逻辑测试（本机 `swift test` 可跑，无模拟器）。
// 覆盖：四角→单应（采样网格角点）、轴对齐裁切、带旋转的合成用例（摆正）、退化四角（重合/共线/
// 非凸/越界）、目标尺寸估算、scale 参数。
import CoreGraphics
import Testing
@testable import DDScannerCore

@Suite("DocumentQuad 形状判定")
struct DocumentQuadShapeTests {
    @Test("轴对齐矩形：面积 / 凸性 / 在单位正方形内")
    func axisAlignedRectangle() {
        let quad = DocumentQuad.fixture.normalized(in: CGSize(width: 100, height: 200))
        #expect(abs(quad.area - 0.8 * 0.8) < 1e-9)
        #expect(quad.isConvex)
        #expect(quad.isWithinUnitSquare())
    }

    @Test("蝴蝶结（交叉）四角判为非凸")
    func bowTieIsNotConvex() {
        let quad = DocumentQuad(
            topLeft: CGPoint(x: 0.1, y: 0.1),
            topRight: CGPoint(x: 0.9, y: 0.9),
            bottomRight: CGPoint(x: 0.9, y: 0.1),
            bottomLeft: CGPoint(x: 0.1, y: 0.9)
        )
        #expect(!quad.isDegenerate)
        #expect(!quad.isConvex)
    }

    @Test("共线四角判为非凸（面积为 0）")
    func collinearIsNotConvex() {
        let quad = DocumentQuad(
            topLeft: CGPoint(x: 0.1, y: 0.1),
            topRight: CGPoint(x: 0.2, y: 0.1),
            bottomRight: CGPoint(x: 0.3, y: 0.1),
            bottomLeft: CGPoint(x: 0.4, y: 0.1)
        )
        #expect(quad.area < 1e-9)
        #expect(!quad.isConvex)
    }

    @Test("越界点被识别；钳制后回到单位正方形内")
    func outOfBoundsAndClamp() {
        let quad = DocumentQuad(
            topLeft: CGPoint(x: -0.1, y: 0.1),
            topRight: CGPoint(x: 1.4, y: 0.1),
            bottomRight: CGPoint(x: 1.0, y: 0.9),
            bottomLeft: CGPoint(x: 0.0, y: 0.9)
        )
        #expect(!quad.isWithinUnitSquare())
        #expect(quad.isWithinUnitSquare(tolerance: 0.5))
        let clamped = quad.clampedToUnitSquare()
        #expect(clamped.isWithinUnitSquare())
        #expect(clamped.topLeft.x == 0)
        #expect(clamped.topRight.x == 1)
    }

    @Test("denormalized 是 normalized 的逆运算")
    func denormalizeRoundTrip() {
        let size = CGSize(width: 100, height: 200)
        let pixel = DocumentQuad.fixture
        let roundTrip = pixel.normalized(in: size).denormalized(in: size)
        #expect(abs(roundTrip.topLeft.x - pixel.topLeft.x) < 1e-9)
        #expect(abs(roundTrip.bottomRight.y - pixel.bottomRight.y) < 1e-9)
    }
}

@Suite("DocumentRectifier")
struct DocumentRectifierTests {
    private static let canvasSize = CGSize(width: 340, height: 260)

    // MARK: 四角 → 单应（采样网格角点）

    @Test("采样网格四角精确落在四角映射位置")
    func gridCornersFollowHomography() throws {
        // 一个刻意不规则的凸四边形（模拟拍摄歪斜的名片）。
        let quad = DocumentQuad(
            topLeft: CGPoint(x: 0.20, y: 0.14),
            topRight: CGPoint(x: 0.86, y: 0.22),
            bottomRight: CGPoint(x: 0.78, y: 0.88),
            bottomLeft: CGPoint(x: 0.12, y: 0.80)
        )
        let plan = try DocumentRectifier.plan(quad: quad, sourceSize: Self.canvasSize)
        let grid = plan.samplingGrid
        #expect(grid.columns == plan.targetWidth && grid.rows == plan.targetHeight)

        func toUnit(_ point: (x: Float, y: Float)) -> CGPoint {
            CGPoint(x: Double((point.x + 1) / 2), y: Double((point.y + 1) / 2))
        }
        let corners: [(Int, Int, CGPoint)] = [
            (0, 0, quad.topLeft),
            (plan.targetWidth - 1, 0, quad.topRight),
            (plan.targetWidth - 1, plan.targetHeight - 1, quad.bottomRight),
            (0, plan.targetHeight - 1, quad.bottomLeft),
        ]
        for (column, row, expected) in corners {
            let mapped = toUnit(try #require(grid.point(column: column, row: row)))
            #expect(abs(mapped.x - expected.x) < 1e-5, "列 \(column) 行 \(row) 的 x 不匹配")
            #expect(abs(mapped.y - expected.y) < 1e-5, "列 \(column) 行 \(row) 的 y 不匹配")
        }
    }

    @Test("轴对齐四角：目标尺寸等于文档像素尺寸")
    func targetSizeMatchesDocumentPixels() throws {
        let quad = DocumentQuad(
            topLeft: CGPoint(x: 0.1, y: 0.1),
            topRight: CGPoint(x: 0.9, y: 0.1),
            bottomRight: CGPoint(x: 0.9, y: 0.9),
            bottomLeft: CGPoint(x: 0.1, y: 0.9)
        )
        let plan = try DocumentRectifier.plan(quad: quad, sourceSize: CGSize(width: 100, height: 200))
        #expect(plan.targetWidth == 80)
        #expect(plan.targetHeight == 160)
    }

    @Test("scale 参数按比例放大输出尺寸")
    func scaleMultipliesTargetSize() throws {
        let quad = DocumentQuad(
            topLeft: CGPoint(x: 0.1, y: 0.1),
            topRight: CGPoint(x: 0.9, y: 0.1),
            bottomRight: CGPoint(x: 0.9, y: 0.9),
            bottomLeft: CGPoint(x: 0.1, y: 0.9)
        )
        let plan = try DocumentRectifier.plan(quad: quad, sourceSize: CGSize(width: 100, height: 200), scale: 0.5)
        #expect(plan.targetWidth == 40)
        #expect(plan.targetHeight == 80)
    }

    @Test("整幅四角 → 恒等矫正，逐像素等于原图")
    func identityFullFrame() throws {
        let source = Self.grayscale([
            [0, 1, 2, 3],
            [4, 5, 6, 7],
            [8, 9, 10, 11],
        ])
        let quad = DocumentQuad(
            topLeft: CGPoint(x: 0, y: 0),
            topRight: CGPoint(x: 1, y: 0),
            bottomRight: CGPoint(x: 1, y: 1),
            bottomLeft: CGPoint(x: 0, y: 1)
        )
        let output = try DocumentRectifier.rectify(source, quad: quad)
        #expect(output.width == 4 && output.height == 3)
        for row in 0 ..< 3 {
            for column in 0 ..< 4 {
                let expected = source.value(x: column, y: row, channel: 0) ?? .nan
                let actual = output.value(x: column, y: row, channel: 0) ?? .nan
                #expect(abs(actual - expected) < 1e-5)
            }
        }
    }

    @Test("轴对齐裁切：抠出的矩形等于源图对应区域")
    func axisAlignedCrop() throws {
        // 4×4 源图；四角取在**像素索引**上（align_corners 约定：归一化 s ↔ 像素 s×(N-1)）：
        // x ∈ [1/3, 1] → 像素列 1...3；y ∈ [0, 2/3] → 像素行 0...2。
        let source = Self.grayscale([
            [0, 1, 2, 3],
            [4, 5, 6, 7],
            [8, 9, 10, 11],
            [12, 13, 14, 15],
        ])
        let quad = DocumentQuad(
            topLeft: CGPoint(x: 1.0 / 3, y: 0),
            topRight: CGPoint(x: 1, y: 0),
            bottomRight: CGPoint(x: 1, y: 2.0 / 3),
            bottomLeft: CGPoint(x: 1.0 / 3, y: 2.0 / 3)
        )
        let output = try DocumentRectifier.rectify(source, quad: quad)
        #expect(output.width == 3 && output.height == 3)
        let expected: [[Float]] = [
            [1, 2, 3],
            [5, 6, 7],
            [9, 10, 11],
        ]
        for row in 0 ..< 3 {
            for column in 0 ..< 3 {
                let actual = output.value(x: column, y: row, channel: 0) ?? .nan
                #expect(abs(actual - expected[row][column]) < 1e-5)
            }
        }
    }

    // MARK: 摆正（deskew）：带旋转的合成用例

    @Test("旋转 7° 的「拍摄件」矫正后行方向与画布轴夹角 ≈ 0")
    func deskewRotatedDocument() throws {
        let synthetic = Self.rotatedCameraImage(angleDegrees: 7)
        let output = try DocumentRectifier.rectify(synthetic.image, quad: synthetic.quad)
        // 最外圈像素靠四角边界，双线性会混入背景（边缘效应）→ 只评判内部区域。
        let angle = Self.darkestLineAngle(of: output, marginRatio: 0.03)
        #expect(abs(angle) < 1.0, "矫正后行方向仍有 \(angle)° 夹角")
        #expect(Self.darkestLineSpread(of: output, marginRatio: 0.03) <= 2)
    }

    @Test("对照：未矫正时行方向夹角 ≈ 7°（证明测试真的在测摆正）")
    func controlUncorrectedStaysRotated() throws {
        let synthetic = Self.rotatedCameraImage(angleDegrees: 7)
        // 不矫正，直接在整幅上取暗线角度；只取文档所在的中间列（外圈无暗线）。
        let angle = Self.darkestLineAngle(of: synthetic.image, marginRatio: 0.3)
        #expect(abs(angle) > 4.0, "未矫正时应保留约 7° 夹角，实际 \(angle)°")
    }

    @Test("旋转 -11° 同样被摆正（方向无关）")
    func deskewNegativeAngle() throws {
        let synthetic = Self.rotatedCameraImage(angleDegrees: -11)
        let output = try DocumentRectifier.rectify(synthetic.image, quad: synthetic.quad)
        #expect(abs(Self.darkestLineAngle(of: output, marginRatio: 0.03)) < 1.0)
    }

    // MARK: 退化四角

    @Test("重合角点（重复点）→ degenerateQuad")
    func duplicateCorners() {
        let quad = DocumentQuad(
            topLeft: CGPoint(x: 0.2, y: 0.2),
            topRight: CGPoint(x: 0.2, y: 0.2),
            bottomRight: CGPoint(x: 0.8, y: 0.8),
            bottomLeft: CGPoint(x: 0.2, y: 0.8)
        )
        #expect(throws: ScannerError.degenerateQuad) {
            try DocumentRectifier.plan(quad: quad, sourceSize: Self.canvasSize)
        }
    }

    @Test("共线角点（面积为零）→ degenerateQuad")
    func collinearCorners() {
        let quad = DocumentQuad(
            topLeft: CGPoint(x: 0.10, y: 0.30),
            topRight: CGPoint(x: 0.40, y: 0.30),
            bottomRight: CGPoint(x: 0.70, y: 0.30),
            bottomLeft: CGPoint(x: 0.95, y: 0.30)
        )
        #expect(throws: ScannerError.degenerateQuad) {
            try DocumentRectifier.plan(quad: quad, sourceSize: Self.canvasSize)
        }
    }

    @Test("非凸（蝴蝶结）四角 → degenerateQuad")
    func nonConvexCorners() {
        let quad = DocumentQuad(
            topLeft: CGPoint(x: 0.10, y: 0.10),
            topRight: CGPoint(x: 0.90, y: 0.90),
            bottomRight: CGPoint(x: 0.90, y: 0.10),
            bottomLeft: CGPoint(x: 0.10, y: 0.90)
        )
        #expect(throws: ScannerError.degenerateQuad) {
            try DocumentRectifier.plan(quad: quad, sourceSize: Self.canvasSize)
        }
    }

    @Test("明显越界四角 → degenerateQuad")
    func outOfBoundsCorners() {
        let quad = DocumentQuad(
            topLeft: CGPoint(x: -0.30, y: 0.10),
            topRight: CGPoint(x: 0.90, y: 0.10),
            bottomRight: CGPoint(x: 0.90, y: 0.90),
            bottomLeft: CGPoint(x: 0.10, y: 0.90)
        )
        #expect(throws: ScannerError.degenerateQuad) {
            try DocumentRectifier.plan(quad: quad, sourceSize: Self.canvasSize)
        }
    }

    // MARK: 合成「拍摄件」工具

    /// 合成一张「相机拍到的旋转文档」：白底 + 一条黑色水平线（文档自身坐标系里水平）。
    /// 返回整幅图与文档四角（归一化，左上原点，TL→TR→BR→BL）。
    private static func rotatedCameraImage(
        angleDegrees: Double
    ) -> (image: FloatImage, quad: DocumentQuad) {
        let documentWidth = 240
        let documentHeight = 160
        let canvasWidth = 340
        let canvasHeight = 260
        let radians = angleDegrees * Double.pi / 180
        let cosAngle = cos(radians)
        let sinAngle = sin(radians)
        let canvasCenter = CGPoint(x: Double(canvasWidth) / 2, y: Double(canvasHeight) / 2)
        let documentCenter = CGPoint(x: Double(documentWidth) / 2, y: Double(documentHeight) / 2)
        let lineRow = documentHeight / 3

        var values = [Float](repeating: 0.5, count: canvasWidth * canvasHeight)
        for row in 0 ..< canvasHeight {
            for column in 0 ..< canvasWidth {
                // 反向旋转：画布像素 → 文档像素。
                let relativeX = Double(column) - canvasCenter.x
                let relativeY = Double(row) - canvasCenter.y
                let documentX = cosAngle * relativeX + sinAngle * relativeY + documentCenter.x
                let documentY = -sinAngle * relativeX + cosAngle * relativeY + documentCenter.y
                guard documentX >= 0, documentX < Double(documentWidth),
                      documentY >= 0, documentY < Double(documentHeight) else { continue }
                let onLine = Int(documentY.rounded(.down)) == lineRow
                values[row * canvasWidth + column] = onLine ? 0 : 1
            }
        }

        /// 文档像素 → 画布像素（正向旋转 + 平移）。
        func placed(_ point: CGPoint) -> CGPoint {
            let relativeX = Double(point.x) - documentCenter.x
            let relativeY = Double(point.y) - documentCenter.y
            return CGPoint(
                x: canvasCenter.x + cosAngle * relativeX - sinAngle * relativeY,
                y: canvasCenter.y + sinAngle * relativeX + cosAngle * relativeY
            )
        }

        func normalized(_ point: CGPoint) -> CGPoint {
            CGPoint(x: point.x / Double(canvasWidth), y: point.y / Double(canvasHeight))
        }

        let quad = DocumentQuad(
            topLeft: normalized(placed(CGPoint(x: 0, y: 0))),
            topRight: normalized(placed(CGPoint(x: documentWidth, y: 0))),
            bottomRight: normalized(placed(CGPoint(x: documentWidth, y: documentHeight))),
            bottomLeft: normalized(placed(CGPoint(x: 0, y: documentHeight)))
        )
        let image = FloatImage(width: canvasWidth, height: canvasHeight, channels: 1, values: values)
        return (image, quad)
    }

    /// 逐列找最暗像素所在行，用首尾两列拟合「行方向」角度（度）；`marginRatio` 为左右各跳过的比例（避开边界）。
    private static func darkestLineAngle(of image: FloatImage, marginRatio: Double) -> Double {
        let rows = darkestRowPerColumn(of: image, marginRatio: marginRatio)
        guard rows.count > 1 else { return 0 }
        let deltaX = Double(rows.count - 1)
        let deltaY = Double(rows[rows.count - 1] - rows[0])
        return atan2(deltaY, deltaX) * 180 / Double.pi
    }

    /// 最暗行在列方向上的最大波动（像素）。
    private static func darkestLineSpread(of image: FloatImage, marginRatio: Double) -> Int {
        let rows = darkestRowPerColumn(of: image, marginRatio: marginRatio)
        guard let minimum = rows.min(), let maximum = rows.max() else { return 0 }
        return maximum - minimum
    }

    private static func darkestRowPerColumn(of image: FloatImage, marginRatio: Double) -> [Int] {
        let margin = max(Int(Double(image.width) * marginRatio), 1)
        let upper = max(image.width - margin, margin + 1)
        var rows = [Int]()
        rows.reserveCapacity(upper - margin)
        for column in margin ..< upper {
            var bestRow = 0
            var bestValue = Float.greatestFiniteMagnitude
            for row in 0 ..< image.height {
                let value = image.values[row * image.width + column]
                if value < bestValue {
                    bestValue = value
                    bestRow = row
                }
            }
            rows.append(bestRow)
        }
        return rows
    }

    /// 由行优先的二维数组构造单通道图（rows = y，元素 = x）。
    private static func grayscale(_ rows: [[Float]]) -> FloatImage {
        let height = rows.count
        let width = rows[0].count
        return FloatImage(width: width, height: height, channels: 1, values: rows.flatMap { $0 })
    }
}

@Suite("FrontEndPlanner（降级契约）")
struct FrontEndPlannerTests {
    private static let size = CGSize(width: 100, height: 200)
    private static let validQuad = DocumentQuad(
        topLeft: CGPoint(x: 0.1, y: 0.1),
        topRight: CGPoint(x: 0.9, y: 0.1),
        bottomRight: CGPoint(x: 0.9, y: 0.9),
        bottomLeft: CGPoint(x: 0.1, y: 0.9)
    )

    @Test("检测为 nil → 回退整帧（rectification 为 nil）")
    func notDetectedFallsBack() {
        let decision = FrontEndPlanner.decide(detection: nil, sourceSize: Self.size)
        #expect(decision.detection == nil)
        #expect(decision.rectification == nil)
        #expect(decision.isFallback)
    }

    @Test("有效检测 → 给出矫正方案，不回退")
    func validDetectionProducesPlan() throws {
        let detection = DocumentDetection(quad: Self.validQuad, confidence: 0.9)
        let decision = FrontEndPlanner.decide(detection: detection, sourceSize: Self.size)
        #expect(!decision.isFallback)
        let plan = try #require(decision.rectification)
        #expect(plan.targetWidth == 80 && plan.targetHeight == 160)
    }

    @Test("退化四角 → 回退整帧（**不抛错**、不崩）")
    func degenerateQuadFallsBackWithoutThrowing() {
        let degenerate = DocumentDetection(
            quad: DocumentQuad(
                topLeft: CGPoint(x: 0.1, y: 0.1),
                topRight: CGPoint(x: 0.9, y: 0.9),
                bottomRight: CGPoint(x: 0.9, y: 0.1),
                bottomLeft: CGPoint(x: 0.1, y: 0.9)
            ),
            confidence: 0.9
        )
        let decision = FrontEndPlanner.decide(detection: degenerate, sourceSize: Self.size)
        #expect(decision.detection != nil)
        #expect(decision.isFallback)
    }

    @Test("越界四角 → 回退整帧（不抛错）")
    func outOfBoundsFallsBackWithoutThrowing() {
        let outOfBounds = DocumentDetection(
            quad: DocumentQuad(
                topLeft: CGPoint(x: -0.4, y: 0.1),
                topRight: CGPoint(x: 0.9, y: 0.1),
                bottomRight: CGPoint(x: 0.9, y: 0.9),
                bottomLeft: CGPoint(x: 0.1, y: 0.9)
            ),
            confidence: 0.5
        )
        #expect(FrontEndPlanner.decide(detection: outOfBounds, sourceSize: Self.size).isFallback)
    }
}
