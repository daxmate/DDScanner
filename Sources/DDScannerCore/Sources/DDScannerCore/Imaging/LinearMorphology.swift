// LinearMorphology —— 线性域大核椭圆形态学闭（`PaperEnhancer` 的纸面底色估计）。
//
// 这是参考实现（批 23/24 spike：`cv2.getStructuringElement(MORPH_ELLIPSE, (K,K))` +
// `cv2.morphologyEx(..., MORPH_CLOSE, ...)`，输入 float32）的**逐像素对齐移植**，不是近似：
//   ① 椭圆核第 `ky` 行的半宽 = `floor(r·√(1−(dy/r)²) + 0.5)`，`r = (K−1)/2`，`dy = ky − K/2`；
//      实测对 K ∈ {3,5,7,…,101} 与 cv2 的核 mask **完全一致**（见批 25 报告「形态学口径」）。
//   ② 闭 = 膨胀 → 腐蚀；Accelerate 无滑窗最小值，腐蚀用「取负 → 膨胀 → 取负」实现
//      （min 与 max 的对偶，浮点精确）。
//   ③ 窗口最大值用 `vDSP_vswmax`（Accelerate 的滑窗最大，HGW 级）。
//   ④ 边界：核行整行越界 → 该行不参与（≡ cv2 的 `morphologyDefaultBorderValue`「越界不参与」）；
//      窗口横向越界 → 用**复制边缘**填充。对**居中窗口**二者数学等价：被复制进来的边缘像素
//      本就落在窗口内（`max(x[0..c+w])` 与把 `x[0]` 重复补进越界位置得到的最大值相同）。
// 因此本实现的输出与 cv2 在 float32 下**逐像素相同**（max/min 精确、结合律无关）。
import Accelerate
import Foundation

enum LinearMorphology {
    /// 椭圆核逐行半宽（长度 = `kernel`）；`kernel ≤ 1` 时核退化为 1×1。
    static func rowHalfWidths(kernel: Int) -> [Int] {
        guard kernel > 1 else { return [0] }
        let radius = Double(kernel - 1) / 2
        let center = kernel / 2
        return (0 ..< kernel).map { index in
            let dy = Double(index - center) / radius
            let squared = 1 - dy * dy
            let value = radius * (squared > 0 ? squared.squareRoot() : 0)
            return Int((value + 0.5).rounded(.down))
        }
    }

    /// 形态学闭（`ed` = 膨胀后腐蚀）；`source` 为行优先单平面。
    static func close(_ source: [Float], width: Int, height: Int, kernel: Int) -> [Float] {
        let dilated = dilate(source, width: width, height: height, kernel: kernel)
        var negated = [Float](repeating: 0, count: dilated.count)
        vDSP_vneg(dilated, 1, &negated, 1, vDSP_Length(dilated.count))
        var eroded = dilate(negated, width: width, height: height, kernel: kernel)
        vDSP_vneg(eroded, 1, &eroded, 1, vDSP_Length(eroded.count))
        return eroded
    }

    /// 椭圆核膨胀（窗口最大值）。未覆盖到的像素保持 `-Float.greatestFiniteMagnitude`；
    /// 因核尺寸恒被钳到 `≤ min(width, height)`，中心核行覆盖每一行，故输出无哨兵残留。
    static func dilate(_ source: [Float], width: Int, height: Int, kernel: Int) -> [Float] {
        let half = kernel / 2
        let widths = rowHalfWidths(kernel: kernel)
        var output = [Float](repeating: -Float.greatestFiniteMagnitude, count: width * height)
        let paddedLength = width + 2 * half
        var padded = [Float](repeating: 0, count: paddedLength)
        var window = [Float](repeating: 0, count: paddedLength)

        source.withUnsafeBufferPointer { src in
            output.withUnsafeMutableBufferPointer { destination in
                padded.withUnsafeMutableBufferPointer { pad in
                    window.withUnsafeMutableBufferPointer { scratch in
                        guard let sourceBase = src.baseAddress,
                              let outputBase = destination.baseAddress,
                              let padBase = pad.baseAddress,
                              let scratchBase = scratch.baseAddress
                        else { return }

                        for row in 0 ..< height {
                            let rowBase = sourceBase + row * width
                            // 复制边缘的行填充：| half | row | half |
                            padBase.update(repeating: rowBase.pointee, count: half)
                            (padBase + half).update(from: rowBase, count: width)
                            (padBase + half + width).update(repeating: rowBase[width - 1], count: half)

                            for index in 0 ..< kernel {
                                let dy = index - half
                                let outputRow = row - dy
                                guard outputRow >= 0, outputRow < height else { continue }
                                let halfWidth = widths[index]
                                let windowLength = 2 * halfWidth + 1
                                // vDSP_vswmax 最多能产出 `paddedLength - windowLength + 1` 个输出
                                // （output[j] = max P[j … j+windowLength-1]）；少给一个就会让最右
                                // 若干列读到 scratch 的陈旧值。
                                let count = paddedLength - windowLength + 1
                                guard count > 0 else { continue }
                                vDSP_vswmax(
                                    padBase, 1, scratchBase, 1,
                                    vDSP_Length(count), vDSP_Length(windowLength)
                                )
                                // 滑窗下标 j 对应输出列 j − half + halfWidth。
                                // 居中窗口对**每一列**都成立（越界部分已由复制边缘的 padding 补上），
                                // 故输出列范围恒为整行 [0, width−1]，scratch 起点 = half − halfWidth
                                // （w ≤ half 恒成立，故非负）。早先把它截到
                                // `width−1 + halfWidth − half` 会漏掉最右若干列 —— 那正是
                                // 端到端对比里「右边缘窄条残差」的根因。
                                let scratchStart = scratchBase + (half - halfWidth)
                                let target = outputBase + outputRow * width
                                vDSP_vmax(target, 1, scratchStart, 1, target, 1, vDSP_Length(width))
                            }
                        }
                    }
                }
            }
        }
        return output
    }
}
