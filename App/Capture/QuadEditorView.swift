// QuadEditorView —— 四角拖拽微调编辑器（App 层，见 docs/architecture.md 批 B2）。
//
// 职责：显示方向已归一化的原图，叠加「四边形外变暗 + 四边连线 + 四个角手柄」，用户拖动手柄微调
// 四角，拖动中显示 2× 放大镜（跟随角点、带十字准星）。几何映射 / 夹紧 / 合法性判定全部委托
// Core 的 QuadEditing，本文件**不复制**任何映射 / 校验逻辑。
//
// 命名坐标空间：quadEditor（DragGesture 与手柄统一绑定，禁止全局坐标硬算）。
import CoreGraphics
import DDScannerCore
import SwiftUI

struct QuadEditorView: View {
    let image: CGImage
    let onConfirm: (DocumentQuad) -> Void
    let onRetake: () -> Void

    @State private var quad: DocumentQuad
    @State private var activeCorner: QuadEditing.Corner?
    @State private var dragAnchor: CGPoint?

    private let handleVisualDiameter: CGFloat = 16
    private let handleHitSize: CGFloat = 44
    private let loupeDiameter: CGFloat = 96
    private let loupeMagnification: CGFloat = 2

    init(image: CGImage, quad: DocumentQuad, onConfirm: @escaping (DocumentQuad) -> Void, onRetake: @escaping () -> Void) {
        self.image = image
        self.onConfirm = onConfirm
        self.onRetake = onRetake
        self._quad = State(initialValue: quad)
    }

    private var imageSize: CGSize {
        CGSize(width: image.width, height: image.height)
    }

    private var clampConfig: QuadEditing.ClampConfig {
        .recommended(forImageSize: imageSize)
    }

    private var validity: QuadEditing.ValidityIssue? {
        QuadEditing.validate(quad)
    }

    private var validityReason: String? {
        guard let issue = validity else { return nil }
        switch issue {
        case .degenerate: return String(localized: "quad.invalid.degenerate")
        case .nonConvex: return String(localized: "quad.invalid.nonConvex")
        case .areaTooSmall: return String(localized: "quad.invalid.areaTooSmall")
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            editorCanvas
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            controlBar
        }
        .background(Color.black)
        .navigationTitle(String(localized: "quad.title"))
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            AppLog.info("进入四角微调编辑", category: .capture)
        }
    }

    // MARK: - 编辑器画布

    private var editorCanvas: some View {
        GeometryReader { proxy in
            let mapping = QuadEditing.AspectFitMapping(
                imageSize: imageSize,
                displayRect: CGRect(origin: .zero, size: proxy.size)
            )
            ZStack {
                Color.black
                Image(decorative: image, scale: 1)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                maskLayer(mapping: mapping)
                edgeLines(mapping: mapping)
                ForEach(QuadEditing.Corner.allCases, id: \.rawValue) { corner in
                    handle(for: corner, mapping: mapping)
                }
                if let active = activeCorner {
                    loupe(for: active, mapping: mapping)
                }
            }
            .coordinateSpace(name: "quadEditor")
        }
        .background(Color.black)
        .clipped()
    }

    /// 四边形外变暗（even-odd：外框整幅 + 内孔四边形）。
    private func maskLayer(mapping: QuadEditing.AspectFitMapping) -> some View {
        Path { path in
            path.addRect(mapping.displayRect)
            let corners = quad.points.map { mapping.viewPoint(forNormalized: $0) }
            path.move(to: corners[0])
            for point in corners.dropFirst() {
                path.addLine(to: point)
            }
            path.closeSubpath()
        }
        .fill(Color.black.opacity(0.5), style: FillStyle(eoFill: true))
        .allowsHitTesting(false)
    }

    /// 四边连线。
    private func edgeLines(mapping: QuadEditing.AspectFitMapping) -> some View {
        Path { path in
            let corners = quad.points.map { mapping.viewPoint(forNormalized: $0) }
            path.move(to: corners[0])
            for point in corners.dropFirst() {
                path.addLine(to: point)
            }
            path.closeSubpath()
        }
        .stroke(Color.white, lineWidth: 2)
        .allowsHitTesting(false)
    }

    /// 单个角手柄（视觉 16pt、命中 44pt）。
    private func handle(for corner: QuadEditing.Corner, mapping: QuadEditing.AspectFitMapping) -> some View {
        let center = mapping.viewPoint(forNormalized: corner.point(in: quad))
        return ZStack {
            Circle()
                .fill(Color.white)
                .frame(width: handleVisualDiameter, height: handleVisualDiameter)
                .overlay(Circle().stroke(Color.black.opacity(0.35), lineWidth: 1))
                .shadow(color: .black.opacity(0.3), radius: 1, y: 1)
        }
        .frame(width: handleHitSize, height: handleHitSize)
        .contentShape(Circle())
        .position(center)
        .accessibilityLabel(cornerLabel(for: corner))
        .accessibilityAddTraits(.isButton)
        .gesture(dragGesture(for: corner, mapping: mapping))
    }

    /// 2× 放大镜：跟随角点、偏移到手指上方、显示角点附近像素 + 十字准星。
    private func loupe(for corner: QuadEditing.Corner, mapping: QuadEditing.AspectFitMapping) -> some View {
        let center = mapping.viewPoint(forNormalized: corner.point(in: quad))
        let crop = loupeImage(centerView: center, mapping: mapping)
        return ZStack {
            if let crop {
                Image(decorative: crop, scale: 1)
                    .resizable()
                    .scaledToFit()
            } else {
                Color.black
            }
            Path { path in
                path.move(to: CGPoint(x: 0, y: loupeDiameter / 2))
                path.addLine(to: CGPoint(x: loupeDiameter, y: loupeDiameter / 2))
                path.move(to: CGPoint(x: loupeDiameter / 2, y: 0))
                path.addLine(to: CGPoint(x: loupeDiameter / 2, y: loupeDiameter))
            }
            .stroke(Color.red, lineWidth: 1)
        }
        .frame(width: loupeDiameter, height: loupeDiameter)
        .clipShape(Circle())
        .overlay(Circle().stroke(Color.white, lineWidth: 1))
        .position(x: center.x, y: center.y - loupeDiameter / 2 - handleHitSize / 2)
        .allowsHitTesting(false)
    }

    // MARK: - 底部操作

    private var controlBar: some View {
        VStack(spacing: 10) {
            Text(String(localized: "quad.hint"))
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            if let reason = validityReason {
                Text(reason)
                    .font(.footnote)
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
            }
            HStack(spacing: 12) {
                Button {
                    onRetake()
                } label: {
                    Text(String(localized: "quad.retake"))
                        .font(.title3)
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)

                Button {
                    onConfirm(quad)
                } label: {
                    Text(String(localized: "quad.confirm"))
                        .font(.title3)
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .disabled(validity != nil)
            }
        }
        .padding()
        .background(.ultraThinMaterial)
    }

    // MARK: - 手势与裁剪

    private func dragGesture(for corner: QuadEditing.Corner, mapping: QuadEditing.AspectFitMapping) -> some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .named("quadEditor"))
            .onChanged { value in
                if activeCorner != corner {
                    activeCorner = corner
                    dragAnchor = mapping.viewPoint(forNormalized: corner.point(in: quad))
                }
                guard let anchor = dragAnchor else { return }
                let proposedView = CGPoint(
                    x: anchor.x + value.translation.width,
                    y: anchor.y + value.translation.height
                )
                let proposed = mapping.normalizedPoint(forView: proposedView)
                quad = QuadEditing.clamp(
                    quad,
                    moving: corner,
                    to: proposed,
                    imageSize: imageSize,
                    config: clampConfig
                )
            }
            .onEnded { _ in
                activeCorner = nil
                dragAnchor = nil
            }
    }

    /// 以角点视图坐标为中心，裁出放大镜要显示的像素区（已夹到图片边界）。
    private func loupeImage(centerView: CGPoint, mapping: QuadEditing.AspectFitMapping) -> CGImage? {
        let sourceViewRadius = loupeDiameter / 2 / loupeMagnification
        let topLeftView = CGPoint(x: centerView.x - sourceViewRadius, y: centerView.y - sourceViewRadius)
        let bottomRightView = CGPoint(x: centerView.x + sourceViewRadius, y: centerView.y + sourceViewRadius)
        let topLeftPixel = mapping.pixelPoint(forView: topLeftView)
        let bottomRightPixel = mapping.pixelPoint(forView: bottomRightView)
        let pixelRect = CGRect(
            x: topLeftPixel.x,
            y: topLeftPixel.y,
            width: bottomRightPixel.x - topLeftPixel.x,
            height: bottomRightPixel.y - topLeftPixel.y
        )
        let bounds = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        let clamped = pixelRect.integral.intersection(bounds)
        guard clamped.width >= 1, clamped.height >= 1 else { return nil }
        return image.cropping(to: clamped)
    }

    private func cornerLabel(for corner: QuadEditing.Corner) -> String {
        switch corner {
        case .topLeft: return String(localized: "quad.corner.topLeft")
        case .topRight: return String(localized: "quad.corner.topRight")
        case .bottomRight: return String(localized: "quad.corner.bottomRight")
        case .bottomLeft: return String(localized: "quad.corner.bottomLeft")
        }
    }
}
