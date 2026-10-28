import AVFoundation
import ReplayKit
import SwiftUI
import UIKit

/// Hosts the `AVSampleBufferDisplayLayer` required by `AVPictureInPictureController`
/// so the user can preview the exact subtitle banner and launch floating PiP over Netflix / Prime Video.
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

/// Wraps Apple's `RPSystemBroadcastPickerView` so the user can start capturing system audio
/// from OTT apps via the bundled ReplayKit Broadcast Upload Extension.
struct SystemBroadcastPickerRepresentable: UIViewRepresentable {
    let preferredExtensionBundleID: String

    func makeUIView(context: Context) -> RPSystemBroadcastPickerView {
        let picker = RPSystemBroadcastPickerView(frame: CGRect(x: 0, y: 0, width: 44, height: 44))
        picker.preferredExtension = preferredExtensionBundleID
        picker.showsMicrophoneButton = true
        return picker
    }

    func updateUIView(_ uiView: RPSystemBroadcastPickerView, context: Context) {}
}
