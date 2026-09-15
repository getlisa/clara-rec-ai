import AVFoundation
import SwiftUI
import UIKit

/// Hosts the controller's `AVSampleBufferDisplayLayer` so compressed frames can be drawn
/// directly, without a decode-to-UIImage round trip per frame.
struct PreviewLayerView: UIViewRepresentable {
    let layer: AVSampleBufferDisplayLayer

    func makeUIView(context: Context) -> PreviewHostView {
        let view = PreviewHostView()
        view.backgroundColor = .black
        view.attach(layer)
        return view
    }

    func updateUIView(_ uiView: PreviewHostView, context: Context) {}
}

final class PreviewHostView: UIView {
    private var displayLayer: AVSampleBufferDisplayLayer?

    func attach(_ layer: AVSampleBufferDisplayLayer) {
        displayLayer?.removeFromSuperlayer()
        layer.videoGravity = .resizeAspect
        self.layer.addSublayer(layer)
        displayLayer = layer
        setNeedsLayout()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        // The hosted layer is not managed by Auto Layout, so it is sized manually.
        displayLayer?.frame = bounds
    }
}
