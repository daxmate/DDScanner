// GridIdentityDeviation / DewarpIdentityGate —— 「偏离恒等」度量与恒等门控的纯逻辑测试
// （本机 `swift test` 可跑，无模拟器）。
//
// 守三条语义：
//   ① 恒等 = 0：恒等网格偏离恰好为 0（含 1×1 退化网格，不崩）；含非有限值 → nil；
//   ② 只看形变：按轴仿射归一化（纯缩放）后偏离回 0 —— 门控不该被「缩放」触发；
//   ③ 门控判据：≤ 阈值 = bypass（**边界值算 bypass**）、> 阈值 = dewarp、
//      度量不可用 = indeterminate（保守跳过）；负阈值钳到 0。
import Testing
@testable import DDScannerCore

@Suite("GridIdentityDeviation")
struct GridIdentityDeviationTests {
    // MARK: - 夹具

    /// 2×2 恒等网格，只把第 0 个点沿 x 平移 `delta`（其余点不动）。
    ///
    /// 2×2 恒等网格的坐标为 x ∈ {-1, 1}、y ∈ {-1, 1}；第 0 点 = (-1, -1)。
    /// 平移后该点位移向量 = (delta, 0) → 模长 = |delta|。
    private static func shiftedFirstPoint(by delta: Float, columns: Int = 2, rows: Int = 2) -> NormalizedSampleGrid {
        let identity = NormalizedSampleGrid.identity(columns: columns, rows: rows)
        var xValues = identity.xValues
        xValues[0] += delta
        return NormalizedSampleGrid(columns: columns, rows: rows, xValues: xValues, yValues: identity.yValues)
    }

    /// 按轴仿射归一化：把每个轴的坐标范围压到恰好 [-1, 1]（只改采样比例，不改形变形状）。
    private static func renormalizedPerAxis(_ grid: NormalizedSampleGrid) -> NormalizedSampleGrid {
        func normalize(_ values: [Float]) -> [Float] {
            guard let minimum = values.min(), let maximum = values.max(), maximum > minimum else {
                return values
            }
            let range = maximum - minimum
            return values.map { 2 * ($0 - minimum) / range - 1 }
        }
        return NormalizedSampleGrid(
            columns: grid.columns,
            rows: grid.rows,
            xValues: normalize(grid.xValues),
            yValues: normalize(grid.yValues)
        )
    }

    // MARK: - ① 恒等 = 0 / 非有限值 = nil

    @Test("恒等网格偏离恰好为 0（浮点精确 0）")
    func identityDeviatesZero() {
        let deviation = NormalizedSampleGrid.identity(columns: 31, rows: 45).deviationFromIdentity()
        #expect(deviation?.maximumMagnitude == 0)
        #expect(deviation?.rmsMagnitude == 0)
    }

    @Test("非有限值：NaN / ±∞ → deviationFromIdentity() == nil")
    func nonFiniteReturnsNil() {
        let nan = NormalizedSampleGrid(
            columns: 2, rows: 2,
            xValues: [.nan, 0, -0.5, 0.5],
            yValues: [-0.5, -0.5, 0, 0.5]
        )
        #expect(nan.deviationFromIdentity() == nil)

        let positiveInfinity = NormalizedSampleGrid(
            columns: 2, rows: 2,
            xValues: [.infinity, 0, -0.5, 0.5],
            yValues: [-0.5, -0.5, 0, 0.5]
        )
        #expect(positiveInfinity.deviationFromIdentity() == nil)

        let negativeInfinity = NormalizedSampleGrid(
            columns: 2, rows: 2,
            xValues: [0, 0, -0.5, 0.5],
            yValues: [-Float.infinity, -0.5, 0, 0.5]
        )
        #expect(negativeInfinity.deviationFromIdentity() == nil)
    }

    @Test("1×1 网格：不崩，恒等 → 0")
    func singlePointGridIsWellDefined() {
        let deviation = NormalizedSampleGrid.identity(columns: 1, rows: 1).deviationFromIdentity()
        #expect(deviation?.maximumMagnitude == 0)
        #expect(deviation?.rmsMagnitude == 0)
    }

    // MARK: - ② 只看形变，不看缩放

    @Test("逐轴仿射缩放：把恒等网格 ×0.5 再按轴归一化回 [-1,1] → 偏离回到 0")
    func axisNormalizedScalingIsIdentity() {
        // 恒等网格整体 ×0.5 是「纯缩放、无形变」；按轴归一化（把每轴范围压回 [-1,1]）只抵消这个缩放，
        // 形状不变 ⇒ 相对恒等网格的偏离必须回到 0（门控不该被缩放触发）。
        let identity = NormalizedSampleGrid.identity(columns: 5, rows: 4)
        let scaled = NormalizedSampleGrid(
            columns: 5,
            rows: 4,
            xValues: identity.xValues.map { $0 * 0.5 },
            yValues: identity.yValues.map { $0 * 0.5 }
        )
        let deviation = Self.renormalizedPerAxis(scaled).deviationFromIdentity()
        #expect(deviation?.maximumMagnitude == 0)
        #expect(deviation?.rmsMagnitude == 0)
    }

    // MARK: - ③ 手算

    @Test("手算：3×2 网格单点平移 (0.3, 0.4) → max = 0.5、rms = 0.5/√6")
    func handCalculatedSinglePointShift() throws {
        // 3×2 恒等网格（align_corners=True）：x = -1 / 0 / 1，y = -1 / 1，共 6 点。
        // 只把第 0 个点 (-1, -1) 平移 (+0.3, +0.4)：位移向量 (0.3, 0.4)，
        //   模长 = √(0.3² + 0.4²) = √(0.09 + 0.16) = √0.25 = 0.5（3-4-5 直角三角形）。
        // 其余 5 点位移 = 0 ⇒ maximumMagnitude = 0.5；
        //   rms = √((0.5² + 0) / 6) = 0.5/√6 ≈ 0.2041241452。
        let identity = NormalizedSampleGrid.identity(columns: 3, rows: 2)
        var xValues = identity.xValues
        var yValues = identity.yValues
        xValues[0] += 0.3
        yValues[0] += 0.4
        let grid = NormalizedSampleGrid(columns: 3, rows: 2, xValues: xValues, yValues: yValues)

        let deviation = try #require(grid.deviationFromIdentity())
        #expect(abs(deviation.maximumMagnitude - 0.5) < 1e-6)
        #expect(abs(deviation.rmsMagnitude - Float(0.5 / 6.0.squareRoot())) < 1e-6)
    }
}

@Suite("DewarpIdentityGate")
struct DewarpIdentityGateTests {
    /// 2×2 恒等网格，第 0 点沿 x 平移 `delta`（位移模长 = |delta|）。
    private static func shiftedFirstPoint(by delta: Float) -> NormalizedSampleGrid {
        let identity = NormalizedSampleGrid.identity(columns: 2, rows: 2)
        var xValues = identity.xValues
        xValues[0] += delta
        return NormalizedSampleGrid(columns: 2, rows: 2, xValues: xValues, yValues: identity.yValues)
    }

    @Test("恒等网格 + 任意阈值 → bypass")
    func identityBypasses() {
        let decision = DewarpIdentityGate(threshold: 0.02).decide(for: .identity(columns: 8, rows: 6))
        #expect(decision == .bypass(GridIdentityDeviation(maximumMagnitude: 0, rmsMagnitude: 0)))
    }

    @Test("已知形变（超过阈值）→ dewarp")
    func deformationDewarps() {
        // 位移模长精确 = 0.5（-1 → -0.5 是二进制精确值），阈值 0.25 < 0.5 → dewarp。
        let grid = Self.shiftedFirstPoint(by: 0.5)
        guard case let .dewarp(deviation) = DewarpIdentityGate(threshold: 0.25).decide(for: grid) else {
            Issue.record("超过阈值应判 dewarp")
            return
        }
        #expect(deviation.maximumMagnitude == 0.5)
    }

    @Test("边界值：位移恰好等于阈值 → bypass（≤ 为含边界）")
    func boundaryIsInclusive() {
        let grid = Self.shiftedFirstPoint(by: 0.5) // maximumMagnitude 精确 = 0.5
        guard case let .bypass(deviation) = DewarpIdentityGate(threshold: 0.5).decide(for: grid) else {
            Issue.record("位移恰等于阈值应判 bypass")
            return
        }
        #expect(deviation.maximumMagnitude == 0.5)
    }

    @Test("度量不可用（网格含非有限值）→ indeterminate（保守不动作）")
    func indeterminateWhenMetricsUnavailable() {
        let grid = NormalizedSampleGrid(
            columns: 2, rows: 2,
            xValues: [.nan, 1, -1, 1],
            yValues: [-1, -1, 1, 1]
        )
        #expect(DewarpIdentityGate(threshold: 0.02).decide(for: grid) == .indeterminate)
    }

    @Test("threshold 传负数 → 钳到 0（恒等 → bypass；非恒等 → dewarp）")
    func negativeThresholdClampsToZero() {
        let gate = DewarpIdentityGate(threshold: -0.5)
        #expect(gate.threshold == 0)
        #expect(gate.decide(for: .identity(columns: 4, rows: 4)) == .bypass(GridIdentityDeviation(maximumMagnitude: 0, rmsMagnitude: 0)))
        guard case .dewarp = gate.decide(for: Self.shiftedFirstPoint(by: 0.5)) else {
            Issue.record("非恒等网格在阈值 0 下应判 dewarp")
            return
        }
    }
}
