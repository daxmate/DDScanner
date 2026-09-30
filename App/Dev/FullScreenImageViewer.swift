// 开发用「全屏图片查看器」——自测页点图看细节（仅 DEBUG）。
//
// 用途：自测页里的阶段图 / 预览图都很小，看不清纸边、折痕与文字锐度；点按任意图 → 全屏黑底呈现，
// 支持捏合缩放（1×…8×）、放大后拖动平移、双击 1×↔2.5×、单击黑底空白处或右上 ❌ 关闭。
// 本文件只做呈现与手势，不碰管线、不重跑任何计算（图像由调用方以 `UIImage` 传入）。
#if DEBUG
    import SwiftUI

    /// 一张可全屏查看的图：由自测页在点按时构造。
    struct ImagePreviewItem: Identifiable {
        let id = UUID()
        let image: UIImage
        /// 阶段名（如「③ 裁切 + 透视矫正」），显示在顶部浮层。
        let title: String
        /// 可选补充信息（真实像素尺寸 / 耗时 / 档位名）。
        let detail: String?
    }

    /// 全屏图片查看器：黑底 + 居中图片 + 顶部浮层。由 `.fullScreenCover(item:)` 注入并呈现。
    struct FullScreenImageViewer: View {
        let item: ImagePreviewItem

        @Environment(\.dismiss) private var dismiss

        /// 当前缩放倍率（1×…8×）。
        @State private var scale: CGFloat = 1
        /// 本次捏合手势开始时的倍率（`MagnifyGesture` 的 `magnification` 是累计值）。
        @State private var baseScale: CGFloat = 1
        /// 当前平移位移（容器坐标，仅放大时非零）。
        @State private var offset: CGSize = .zero
        /// 本次拖动手势开始时的位移。
        @State private var baseOffset: CGSize = .zero

        /// 缩放上限；双击目标倍率。
        private let maximumScale: CGFloat = 8
        private let doubleTapScale: CGFloat = 2.5

        var body: some View {
            GeometryReader { proxy in
                let container = proxy.size
                ZStack {
                    Color.black.ignoresSafeArea()
                    imageLayer(in: container)
                    // 手势层：不随图片缩放变换，命中坐标即容器坐标，便于边界钳制与命中判定。
                    Color.clear
                        .contentShape(Rectangle())
                        .gesture(
                            dragGesture(container: container)
                                .simultaneously(with: magnifyGesture(container: container))
                        )
                        .onTapGesture(count: 2) { location in
                            handleDoubleTap(at: location, in: container)
                        }
                        .onTapGesture(count: 1) { location in
                            handleSingleTap(at: location, in: container)
                        }
                    topOverlay
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .background(Color.black.ignoresSafeArea())
            .onAppear { reset() }
        }

        // MARK: 视图层

        private func imageLayer(in container: CGSize) -> some View {
            Image(uiImage: item.image)
                .resizable()
                .scaledToFit()
                .frame(width: container.width, height: container.height)
                .scaleEffect(scale)
                .offset(offset)
                .accessibilityLabel(item.title)
                .allowsHitTesting(false)
        }

        private var topOverlay: some View {
            VStack {
                HStack(alignment: .top, spacing: 12) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.title)
                            .font(.headline)
                            .foregroundStyle(.white)
                        if let detail = item.detail, !detail.isEmpty {
                            Text(detail)
                                .font(.caption)
                                .foregroundStyle(.white.opacity(0.75))
                        }
                    }
                    Spacer(minLength: 0)
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "xmark")
                            .font(.body.weight(.semibold))
                            .foregroundStyle(.white)
                            .padding(10)
                            .background(.ultraThinMaterial, in: Circle())
                    }
                    .accessibilityLabel("关闭")
                }
                .padding()
                Spacer(minLength: 0)
            }
        }

        // MARK: 手势

        private func magnifyGesture(container: CGSize) -> some Gesture {
            MagnifyGesture()
                .onChanged { value in
                    let proposed = max(0.2, min(baseScale * value.magnification, maximumScale))
                    scale = proposed
                    offset = clampedOffset(offset, scale: proposed, container: container)
                }
                .onEnded { _ in
                    if scale < 1 {
                        // 松手回弹到 1×，位移一并归零。
                        withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
                            scale = 1
                            baseScale = 1
                            offset = .zero
                            baseOffset = .zero
                        }
                    } else {
                        if scale > maximumScale { scale = maximumScale }
                        baseScale = scale
                        offset = clampedOffset(offset, scale: scale, container: container)
                        baseOffset = offset
                    }
                }
        }

        private func dragGesture(container: CGSize) -> some Gesture {
            DragGesture()
                .onChanged { value in
                    // 仅放大（> 1×）时可平移；未放大时钳制结果恒为 0。
                    guard scale > 1 else { return }
                    let proposed = CGSize(
                        width: baseOffset.width + value.translation.width,
                        height: baseOffset.height + value.translation.height
                    )
                    offset = clampedOffset(proposed, scale: scale, container: container)
                }
                .onEnded { _ in
                    offset = clampedOffset(offset, scale: scale, container: container)
                    baseOffset = offset
                }
        }

        private func handleDoubleTap(at location: CGPoint, in container: CGSize) {
            if scale > 1.01 {
                // 已放大 → 回到 1×（以整图居中）。
                withAnimation(.easeInOut(duration: 0.25)) {
                    scale = 1
                    baseScale = 1
                    offset = .zero
                    baseOffset = .zero
                }
                return
            }
            let target = doubleTapScale
            let center = CGPoint(x: container.width / 2, y: container.height / 2)
            // 落在「未缩放图片坐标」上的点，放大后应仍停在同一屏幕位置。
            let point = CGPoint(x: location.x - center.x, y: location.y - center.y)
            let source = CGPoint(
                x: (point.x - offset.width) / scale,
                y: (point.y - offset.height) / scale
            )
            let proposed = CGSize(
                width: point.x - source.x * target,
                height: point.y - source.y * target
            )
            let clamped = clampedOffset(proposed, scale: target, container: container)
            withAnimation(.easeInOut(duration: 0.25)) {
                scale = target
                baseScale = target
                offset = clamped
                baseOffset = clamped
            }
        }

        private func handleSingleTap(at location: CGPoint, in container: CGSize) {
            // 单击「黑底空白处」才关闭；点在图片上不关闭（不与双击冲突）。
            guard !isPointOnImage(location, in: container) else { return }
            dismiss()
        }

        // MARK: 几何

        /// 图片按 `scaledToFit` 填充容器后的显示尺寸（未乘缩放倍率）。
        private func fittedSize(in container: CGSize) -> CGSize {
            let imageSize = item.image.size
            guard imageSize.width > 0, imageSize.height > 0,
                  container.width > 0, container.height > 0 else { return .zero }
            let factor = min(container.width / imageSize.width, container.height / imageSize.height)
            return CGSize(width: imageSize.width * factor, height: imageSize.height * factor)
        }

        /// 平移边界钳制：图片小于容器时位移归零；超出时最多把图片边缘拖到容器边缘。
        private func clampedOffset(_ offset: CGSize, scale: CGFloat, container: CGSize) -> CGSize {
            let fitted = fittedSize(in: container)
            let scaled = CGSize(width: fitted.width * scale, height: fitted.height * scale)
            let maximumX = max(0, (scaled.width - container.width) / 2)
            let maximumY = max(0, (scaled.height - container.height) / 2)
            return CGSize(
                width: min(max(offset.width, -maximumX), maximumX),
                height: min(max(offset.height, -maximumY), maximumY)
            )
        }

        /// 命中判定：该点是否落在当前显示中的图片矩形内。
        private func isPointOnImage(_ location: CGPoint, in container: CGSize) -> Bool {
            let fitted = fittedSize(in: container)
            guard fitted.width > 0, fitted.height > 0 else { return false }
            let scaled = CGSize(width: fitted.width * scale, height: fitted.height * scale)
            let center = CGPoint(
                x: container.width / 2 + offset.width,
                y: container.height / 2 + offset.height
            )
            let rect = CGRect(
                x: center.x - scaled.width / 2,
                y: center.y - scaled.height / 2,
                width: scaled.width,
                height: scaled.height
            )
            return rect.contains(location)
        }

        /// 每次展示都从重置状态开始（缩放 1×、位移 0）。
        private func reset() {
            scale = 1
            baseScale = 1
            offset = .zero
            baseOffset = .zero
        }
    }
#endif
