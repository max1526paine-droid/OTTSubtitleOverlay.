import AVFoundation
import AVKit
import CoreMedia
import CoreVideo
import UIKit

/// Renders real-time English subtitles into a wide `AVSampleBufferDisplayLayer` video stream
/// and presents it inside an iOS Picture-in-Picture (PiP) floating overlay window that stays
/// on top of Netflix, Amazon Prime Video, Crunchyroll, Disney+, and other OTT apps.
@MainActor
final class PiPSubtitleManager: NSObject, ObservableObject {
    static let shared = PiPSubtitleManager()

    let displayLayer = AVSampleBufferDisplayLayer()
    private var pipController: AVPictureInPictureController?
    private var refreshTimer: Timer?
    private var backgroundTaskID: UIBackgroundTaskIdentifier = .invalid

    @Published var isPiPActive: Bool = false
    @Published var isPiPPossible: Bool = false
    @Published var currentOriginalLine: String? = "기훈 씨, 이제 선택할 시간입니다."
    @Published var currentEnglishLine: String = "Gi-hun, it is time to make your choice now."
    @Published var statusBadgeText: String = "🇰🇷 KO → EN • Ready"
    @Published var styleSettings = SubtitleStyleSettings() {
        didSet {
            renderCurrentFrame()
        }
    }

    /// Callback triggered when the user taps Play/Pause or Skip buttons inside the floating PiP overlay.
    var onPlayPauseToggled: ((Bool) -> Void)?
    var onSkipRequested: ((TimeInterval) -> Void)?
    var isPlaybackPaused: Bool = false

    private let frameWidth: Int = 1280
    private let frameHeight: Int = 260

    override init() {
        super.init()
        configureAudioSessionForOTTCoexistence()
        setupDisplayLayer()
        observeLifecycleNotifications()
    }

    // MARK: - Audio Session Coexistence (Never Pause Netflix / Prime Video)

    func configureAudioSessionForOTTCoexistence(enableMicCapture: Bool = false) {
        let session = AVAudioSession.sharedInstance()
        do {
            if enableMicCapture {
                try session.setCategory(
                    .playAndRecord,
                    mode: .measurement,
                    options: [.mixWithOthers, .defaultToSpeaker, .allowBluetoothA2DP, .allowAirPlay]
                )
            } else {
                // .mixWithOthers is CRITICAL so Netflix & Amazon Prime audio/video keep playing
                try session.setCategory(
                    .playback,
                    mode: .default,
                    options: [.mixWithOthers]
                )
            }
            try session.setActive(true, options: [])
        } catch {
            print("[PiPSubtitleManager] AudioSession configuration warning: \(error.localizedDescription)")
        }
    }

    // MARK: - Display Layer & PiP Controller Setup

    private func setupDisplayLayer() {
        displayLayer.videoGravity = .resizeAspect
        displayLayer.backgroundColor = UIColor.black.cgColor

        // Enqueue initial frame immediately so AVPictureInPictureController recognizes valid video dimensions
        renderCurrentFrame()

        guard AVPictureInPictureController.isPictureInPictureSupported() else {
            print("[PiPSubtitleManager] Picture-in-Picture is not supported on this device.")
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

        startFrameHeartbeat()
    }

    private func startFrameHeartbeat() {
        refreshTimer?.invalidate()
        // Keep feeding CMSampleBuffers at 2 fps in .common RunLoop mode so PiP stays alive
        // even when scrolling, switching to Netflix/Prime, or when the device locks.
        let timer = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.renderCurrentFrame()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.refreshTimer = timer
    }

    // MARK: - Background & Lock Screen Persistence

    private func observeLifecycleNotifications() {
        NotificationCenter.default.addObserver(
            forName: UIApplication.didEnterBackgroundNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.beginExtendedBackgroundExecution()
                self?.renderCurrentFrame()
            }
        }

        NotificationCenter.default.addObserver(
            forName: UIApplication.willEnterForegroundNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.endExtendedBackgroundExecution()
                self?.renderCurrentFrame()
            }
        }
    }

    private func beginExtendedBackgroundExecution() {
        guard styleSettings.keepActiveWhenLockedOrBackgrounded else { return }
        UIApplication.shared.isIdleTimerDisabled = true
        if backgroundTaskID == .invalid {
            backgroundTaskID = UIApplication.shared.beginBackgroundTask(withName: "OTTSubtitleOverlayPiP") { [weak self] in
                Task { @MainActor in
                    self?.endExtendedBackgroundExecution()
                }
            }
        }
    }

    private func endExtendedBackgroundExecution() {
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

    func updateSubtitle(original: String?, english: String, badge: String? = nil) {
        self.currentOriginalLine = original
        self.currentEnglishLine = english
        if let badge {
            self.statusBadgeText = badge
        }
        renderCurrentFrame()
    }

    // MARK: - CoreGraphics -> CVPixelBuffer -> CMSampleBuffer Rendering

    func renderCurrentFrame() {
        if displayLayer.status == .failed {
            displayLayer.flush()
        }

        guard let pixelBuffer = createSubtitlePixelBuffer() else { return }
        guard let sampleBuffer = createSampleBuffer(from: pixelBuffer) else { return }

        displayLayer.enqueue(sampleBuffer)
    }

    private func createSubtitlePixelBuffer() -> CVPixelBuffer? {
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

        guard status == kCVReturnSuccess, let buffer = pixelBuffer else {
            return nil
        }

        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }

        guard let baseAddress = CVPixelBufferGetBaseAddress(buffer) else {
            return nil
        }

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
        ) else {
            return nil
        }

        // Flip coordinate system so UIKit/NSString drawing renders top-down naturally
        context.translateBy(x: 0, y: CGFloat(frameHeight))
        context.scaleBy(x: 1.0, y: -1.0)

        UIGraphicsPushContext(context)
        drawSubtitleBanner(in: CGRect(x: 0, y: 0, width: frameWidth, height: frameHeight))
        UIGraphicsPopContext()

        return buffer
    }

    private func drawSubtitleBanner(in rect: CGRect) {
        // 1. Deep cinema backdrop
        let bgAlpha = styleSettings.backgroundOpacity
        UIColor(red: 0.05, green: 0.06, blue: 0.09, alpha: 1.0).setFill()
        UIRectFill(rect)

        let cardRect = rect.insetBy(dx: 16, dy: 12)
        let cardPath = UIBezierPath(roundedRect: cardRect, cornerRadius: 20)
        UIColor(red: 0.10, green: 0.12, blue: 0.18, alpha: bgAlpha).setFill()
        cardPath.fill()

        UIColor.white.withAlphaComponent(0.16).setStroke()
        cardPath.lineWidth = 2.0
        cardPath.stroke()

        var currentY: CGFloat = 24.0
        let horizontalPadding: CGFloat = 38.0
        let availableWidth = rect.width - (horizontalPadding * 2)

        // 2. Optional Status Header Badge (Language + Active AI Provider + Sync Offset)
        if styleSettings.showStatusHeaderInPiP {
            let badgeParagraph = NSMutableParagraphStyle()
            badgeParagraph.alignment = .center

            let badgeAttrs: [NSAttributedString.Key: Any] = [
                .font: UIFont.systemFont(ofSize: 20, weight: .semibold),
                .foregroundColor: UIColor(red: 0.68, green: 0.78, blue: 0.98, alpha: 0.95),
                .paragraphStyle: badgeParagraph
            ]
            let badgeRect = CGRect(x: horizontalPadding, y: currentY, width: availableWidth, height: 28)
            (statusBadgeText as NSString).draw(in: badgeRect, withAttributes: badgeAttrs)
            currentY += 32.0
        } else {
            currentY += 12.0
        }

        // 3. Optional Original Foreign Dialogue Line (Korean / Japanese / etc.)
        if styleSettings.showOriginalLanguageLine,
           let orig = currentOriginalLine,
           !orig.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let origParagraph = NSMutableParagraphStyle()
            origParagraph.alignment = .center
            origParagraph.lineBreakMode = .byTruncatingTail

            let origAttrs: [NSAttributedString.Key: Any] = [
                .font: UIFont.systemFont(ofSize: max(22, styleSettings.fontSize * 0.72), weight: .medium),
                .foregroundColor: UIColor.white.withAlphaComponent(0.75),
                .paragraphStyle: origParagraph
            ]
            let origRect = CGRect(x: horizontalPadding, y: currentY, width: availableWidth, height: 36)
            (orig as NSString).draw(in: origRect, withAttributes: origAttrs)
            currentY += 40.0
        } else {
            currentY += 14.0
        }

        // 4. Primary Translated English Subtitle Line (Bold Cinema Typography with Shadow)
        let engParagraph = NSMutableParagraphStyle()
        engParagraph.alignment = .center
        engParagraph.lineBreakMode = .byWordWrapping

        let shadow = NSShadow()
        shadow.shadowColor = UIColor.black.withAlphaComponent(0.95)
        shadow.shadowOffset = CGSize(width: 0, height: 2)
        shadow.shadowBlurRadius = 4.0

        let engFontSize = styleSettings.fontSize * 1.45
        let engAttrs: [NSAttributedString.Key: Any] = [
            .font: UIFont.systemFont(ofSize: engFontSize, weight: .bold),
            .foregroundColor: styleSettings.textColor.uiColor,
            .paragraphStyle: engParagraph,
            .shadow: shadow
        ]

        let remainingHeight = max(60, rect.height - currentY - 18)
        let engRect = CGRect(x: horizontalPadding, y: currentY, width: availableWidth, height: remainingHeight)
        let displayEnglish = currentEnglishLine.isEmpty ? "Listening for dialogue..." : currentEnglishLine
        (displayEnglish as NSString).draw(in: engRect, withAttributes: engAttrs)
    }

    private func createSampleBuffer(from pixelBuffer: CVPixelBuffer) -> CMSampleBuffer? {
        var formatDescription: CMVideoFormatDescription?
        let formatStatus = CMVideoFormatDescriptionCreateForImageBuffer(
            allocator: kCFAllocatorDefault,
            imageBuffer: pixelBuffer,
            formatDescriptionOut: &formatDescription
        )
        guard formatStatus == noErr, let formatDesc = formatDescription else {
            return nil
        }

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

// MARK: - AVPictureInPictureControllerDelegate & SampleBufferPlaybackDelegate

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
            self.isPlaybackPaused = !playing
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
            // Tapping +10s / -10s inside the floating PiP window nudges subtitle sync by +0.5s / -0.5s!
            let nudge: TimeInterval = seconds >= 0 ? 0.5 : -0.5
            self.onSkipRequested?(nudge)
            completionHandler()
        }
    }
}
