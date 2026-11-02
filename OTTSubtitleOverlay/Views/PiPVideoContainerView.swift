import AVFoundation
import SwiftUI
import UIKit

/// Hosts the `AVSampleBufferDisplayLayer` required by `AVPictureInPictureController`
/// so the user can preview the subtitle banner and float it over Netflix / Prime Video.
struct PiPVideoContainerView: UIViewRepresentable {
    let displayLayer: AVSampleBufferDisplayLayer

    func makeUIView(context: Context) -> SampleBufferHostView {
        let view = SampleBufferHostView()
        view.attach(displayLayer: displayLayer)
        return view
    }

    func updateUIView(_ uiView: SampleBufferHostView, context: Context) {
        uiView.setNeedsLayout()
    }
}

final class SampleBufferHostView: UIView {
    private weak var attachedLayer: AVSampleBufferDisplayLayer?

    func attach(displayLayer: AVSampleBufferDisplayLayer) {
        if attachedLayer !== displayLayer {
            attachedLayer?.removeFromSuperlayer()
            displayLayer.frame = bounds
            layer.addSublayer(displayLayer)
            attachedLayer = displayLayer
        }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        attachedLayer?.frame = bounds
        CATransaction.commit()
    }
}
