import AVFoundation
import AVKit
import CoreMedia
import CoreVideo
import UIKit

/// Renders English subtitles into a slim, floating Picture-in-Picture (PiP) window
/// that stays on top of Netflix, Amazon Prime Video, Disney+, and other apps.
@MainActor
final class PiPSubtitleManager: NSObject, ObservableObject {
    static let shared = PiPSubtitleManager()

    let displayLayer = AVSampleBufferDisplayLayer()
    private var pipController: AVPictureInPictureController?
    private var refreshTimer: Timer?
    private var backgroundTaskID: UIBackgroundTaskIdentifier = .invalid

    @Published var isPiPActive: Bool = false
    @Published var isPiPPossible: Bool = false
    @Published var currentText: String = "Search any show or movie to begin subtitles"
    @Published var statusBadgeText: String = "SubFloat • Ready"

    var onPlayPauseToggled: ((Bool) -> Void)?
    var onSkipRequested: ((Double) -> Void)?

    private let frameWidth: Int = 1280
    private let frameHeight: Int = 170

    override init() {
        super.init()
        configureAudioSession()
        setupDisplayLayer()
        observeLifecycle()
    }

    // MARK: - Audio Session (Never pause or mute Netflix / Prime Video)

    private func configureAudioSession() {
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playback, mode: .default, options: [.mixWithOthers])
            try session.setActive(true, options: [])
        } catch {
            print("[PiP] AudioSession error: \(error.localizedDescription)")
        }
    }

    // MARK: - Setup PiP Controller

    private func setupDisplayLayer() {
        displayLayer.videoGravity = .resizeAspect
        displayLayer.backgroundColor = UIColor.black.cgColor

        renderCurrentFrame()

        guard AVPictureInPictureController.isPictureInPictureSupported() else {
            return
        }

        let contentSource = AVPictureInPictureController.ContentSource(
            sampleBufferDisplayLayer: displayLayer,
            playbackDelegate: self
        )

        let controller = AVPictureInPictureController(contentSource: contentSource)
        controller.delegate = self
        if #available(iOS 14.2, *) {
            controller.canStartPictureInPictureAutomaticallyFromInline = true
        }
        self.pipController = controller
        self.isPiPPossible = true

        startHeartbeat()
    }

    private func startHeartbeat() {
        refreshTimer?.invalidate()
        let timer = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.renderCurrentFrame()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.refreshTimer = timer
    }

    private func observeLifecycle() {
        NotificationCenter.default.addObserver(
            forName: UIApplication.didEnterBackgroundNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.beginBackgroundTask()
                self?.renderCurrentFrame()
            }
        }

        NotificationCenter.default.addObserver(
            forName: UIApplication.willEnterForegroundNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.endBackgroundTask()
                self?.renderCurrentFrame()
            }
        }
    }

    private func beginBackgroundTask() {
        UIApplication.shared.isIdleTimerDisabled = true
        if backgroundTaskID == .invalid {
            backgroundTaskID = UIApplication.shared.beginBackgroundTask(withName: "SubFloatPiP") { [weak self] in
                Task { @MainActor in
                    self?.endBackgroundTask()
                }
            }
        }
    }

    private func endBackgroundTask() {
        if backgroundTaskID != .invalid {
            UIApplication.shared.endBackgroundTask(backgroundTaskID)
            backgroundTaskID = .invalid
        }
    }

    // MARK: - Public Controls

    func togglePiP() {
        guard let pipController else { return }
        renderCurrentFrame()
        if pipController.isPictureInPictureActive {
            pipController.stopPictureInPicture()
        } else {
            pipController.startPictureInPicture()
        }
    }

    func startPiPIfNeeded() {
        guard let pipController, !pipController.isPictureInPictureActive else { return }
        renderCurrentFrame()
        pipController.startPictureInPicture()
    }

    func updateSubtitle(text: String, badge: String? = nil) {
        self.currentText = text
        if let badge {
            self.statusBadgeText = badge
        }
        renderCurrentFrame()
    }

    // MARK: - Frame Rendering (CoreGraphics -> CVPixelBuffer -> CMSampleBuffer)

    func renderCurrentFrame() {
        if displayLayer.status == .failed {
            displayLayer.flush()
        }

        guard let pixelBuffer = createPixelBuffer() else { return }
        guard let sampleBuffer = createSampleBuffer(from: pixelBuffer) else { return }

        displayLayer.enqueue(sampleBuffer)
    }

    private func createPixelBuffer() -> CVPixelBuffer? {
        var pixelBuffer: CVPixelBuffer?
        let attrs: [CFString: Any] = [
            kCVPixelBufferCGImageCompatibilityKey: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey: true,
            kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary
        ]

        let status = CVPixelBufferCreate(
            kCFAllocatorDefault,
            frameWidth,
            frameHeight,
            kCVPixelFormatType_32BGRA,
            attrs as CFDictionary,
            &pixelBuffer
        )

        guard status == kCVReturnSuccess, let buffer = pixelBuffer else { return nil }

        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }

        guard let baseAddress = CVPixelBufferGetBaseAddress(buffer) else { return nil }

        let bytesPerRow = CVPixelBufferGetBytesPerRow(buffer)
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.premultipliedFirst.rawValue

        guard let context = CGContext(
            data: baseAddress,
            width: frameWidth,
            height: frameHeight,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: colorSpace,
            bitmapInfo: bitmapInfo
        ) else { return nil }

        context.translateBy(x: 0, y: CGFloat(frameHeight))
        context.scaleBy(x: 1.0, y: -1.0)

        UIGraphicsPushContext(context)
        drawSubtitleBanner(in: CGRect(x: 0, y: 0, width: frameWidth, height: frameHeight))
        UIGraphicsPopContext()

        return buffer
    }

    private func drawSubtitleBanner(in rect: CGRect) {
        UIGraphicsGetCurrentContext()?.clear(rect)

        let cardRect = rect.insetBy(dx: 12, dy: 8)
        let cardPath = UIBezierPath(roundedRect: cardRect, cornerRadius: 18)

        // Translucent dark cinema pill backdrop (40% opacity)
        UIColor(red: 0.04, green: 0.05, blue: 0.08, alpha: 0.40).setFill()
        cardPath.fill()

        UIColor.white.withAlphaComponent(0.12).setStroke()
        cardPath.lineWidth = 1.0
        cardPath.stroke()

        let horizontalPadding: CGFloat = 24.0
        let availableWidth = rect.width - (horizontalPadding * 2)

        // Status Header Badge
        let badgeParagraph = NSMutableParagraphStyle()
        badgeParagraph.alignment = .center

        let badgeAttrs: [NSAttributedString.Key: Any] = [
            .font: UIFont.systemFont(ofSize: 20, weight: .semibold),
            .foregroundColor: UIColor(red: 0.70, green: 0.82, blue: 1.0, alpha: 0.95),
            .paragraphStyle: badgeParagraph
        ]
        let badgeRect = CGRect(x: horizontalPadding, y: 16.0, width: availableWidth, height: 26)
        (statusBadgeText as NSString).draw(in: badgeRect, withAttributes: badgeAttrs)

        // Primary English Subtitle Line (Cinema Yellow Typography)
        let textParagraph = NSMutableParagraphStyle()
        textParagraph.alignment = .center
        textParagraph.lineBreakMode = .byWordWrapping

        let shadow = NSShadow()
        shadow.shadowColor = UIColor.black.withAlphaComponent(0.95)
        shadow.shadowOffset = CGSize(width: 0, height: 2)
        shadow.shadowBlurRadius = 4.0

        let textAttrs: [NSAttributedString.Key: Any] = [
            .font: UIFont.systemFont(ofSize: 42, weight: .bold),
            .foregroundColor: UIColor(red: 1.0, green: 0.92, blue: 0.23, alpha: 1.0),
            .paragraphStyle: textParagraph,
            .shadow: shadow
        ]

        let textRect = CGRect(x: horizontalPadding, y: 48.0, width: availableWidth, height: 110)
        (currentText as NSString).draw(in: textRect, withAttributes: textAttrs)
    }

    private func createSampleBuffer(from pixelBuffer: CVPixelBuffer) -> CMSampleBuffer? {
        var formatDescription: CMVideoFormatDescription?
        let formatStatus = CMVideoFormatDescriptionCreateForImageBuffer(
            allocator: kCFAllocatorDefault,
            imageBuffer: pixelBuffer,
            formatDescriptionOut: &formatDescription
        )
        guard formatStatus == noErr, let formatDesc = formatDescription else { return nil }

        let now = CMClockGetTime(CMClockGetHostTimeClock())
        var timingInfo = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: 2),
            presentationTimeStamp: now,
            decodeTimeStamp: .invalid
        )

        var sampleBuffer: CMSampleBuffer?
        let sampleStatus = CMSampleBufferCreateReadyWithImageBuffer(
            allocator: kCFAllocatorDefault,
            imageBuffer: pixelBuffer,
            formatDescription: formatDesc,
            sampleTiming: &timingInfo,
            sampleBufferOut: &sampleBuffer
        )

        guard sampleStatus == noErr else { return nil }
        return sampleBuffer
    }
}

// MARK: - AVPictureInPictureControllerDelegate & Playback Controls

extension PiPSubtitleManager: AVPictureInPictureControllerDelegate, AVPictureInPictureSampleBufferPlaybackDelegate {
    nonisolated func pictureInPictureControllerDidStartPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) {
        Task { @MainActor in
            self.isPiPActive = true
            self.renderCurrentFrame()
        }
    }

    nonisolated func pictureInPictureControllerDidStopPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) {
        Task { @MainActor in
            self.isPiPActive = false
        }
    }

    nonisolated func pictureInPictureController(
        _ pictureInPictureController: AVPictureInPictureController,
        setPlaying playing: Bool
    ) {
        Task { @MainActor in
            self.onPlayPauseToggled?(playing)
            pictureInPictureController.invalidatePlaybackState()
        }
    }

    nonisolated func pictureInPictureControllerTimeRangeForPlayback(
        _ pictureInPictureController: AVPictureInPictureController
    ) -> CMTimeRange {
        CMTimeRange(start: .zero, duration: CMTime(seconds: 36000, preferredTimescale: 600))
    }

    nonisolated func pictureInPictureControllerIsPlaybackPaused(
        _ pictureInPictureController: AVPictureInPictureController
    ) -> Bool {
        false
    }

    nonisolated func pictureInPictureController(
        _ pictureInPictureController: AVPictureInPictureController,
        didTransitionToRenderSize newRenderSize: CMVideoDimensions
    ) {
        Task { @MainActor in
            self.renderCurrentFrame()
        }
    }

    nonisolated func pictureInPictureController(
        _ pictureInPictureController: AVPictureInPictureController,
        skipByInterval skipInterval: CMTime,
        completion completionHandler: @escaping () -> Void
    ) {
        let seconds = CMTimeGetSeconds(skipInterval)
        Task { @MainActor in
            // Tapping +10s / -10s inside PiP jumps to Next / Previous dialogue line!
            self.onSkipRequested?(seconds)
            completionHandler()
        }
    }
}
