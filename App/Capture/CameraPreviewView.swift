// CameraPreviewView —— `AVCaptureVideoPreviewLayer` 的 SwiftUI 包装（App 层，见 docs/architecture.md 批 B1）。
//
// 只做一件事：把会话画面铺满视图（`resizeAspectFill`）。不碰管线、不持状态、不启动会话
// （启动/停止由 `CaptureFlowView` 按页面生命周期调用 `CameraCaptureService`）。
import AVFoundation
import SwiftUI
import UIKit

struct CameraPreviewView: UIViewRepresentable {
    let session: AVCaptureSession

    func makeUIView(context: Context) -> PreviewContainerView {
        let view = PreviewContainerView()
        view.previewLayer.session = session
        return view
    }

    func updateUIView(_ uiView: PreviewContainerView, context: Context) {
        if uiView.previewLayer.session !== session {
            uiView.previewLayer.session = session
        }
    }

    /// 以 `AVCaptureVideoPreviewLayer` 为 backing layer 的容器视图。
    final class PreviewContainerView: UIView {
        override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }

        var previewLayer: AVCaptureVideoPreviewLayer {
            guard let layer = layer as? AVCaptureVideoPreviewLayer else {
                preconditionFailure("layerClass 必须是 AVCaptureVideoPreviewLayer")
            }
            return layer
        }

        override init(frame: CGRect) {
            super.init(frame: frame)
            previewLayer.videoGravity = .resizeAspectFill
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) {
            fatalError("init(coder:) 未实现")
        }
    }
}
