import Combine
import Foundation

/// Drives synchronized `.srt` / `.vtt` subtitle playback in the floating PiP overlay
/// while the user watches Netflix, Amazon Prime Video, Crunchyroll, or Disney+.
@MainActor
final class SubtitleSyncEngine: ObservableObject {
    static let shared = SubtitleSyncEngine()

    @Published var currentTrack: SubtitleTrack
    @Published var isPlaying: Bool = false
    @Published var currentTime: TimeInterval = 0.0
    @Published var syncOffsetSeconds: TimeInterval = 0.0
    @Published var activeCue: SubtitleCue?
    @Published var isTranslatingTrack: Bool = false
    @Published var translationProgress: Double = 0.0

    private var playbackTimer: Timer?
    private var lastTickDate: Date?

    init() {
        let initialTrack = OpenSubtitlesService.builtInTracks().first!
        self.currentTrack = initialTrack
        self.activeCue = initialTrack.cues.first

        // Connect PiP transport controls (Play/Pause & +10/-10 skip buttons inside PiP overlay)
        PiPSubtitleManager.shared.onPlayPauseToggled = { [weak self] shouldPlay in
            Task { @MainActor in
                guard let self else { return }
                if shouldPlay {
                    self.play()
                } else {
                    self.pause()
                }
            }
        }

        PiPSubtitleManager.shared.onSkipRequested = { [weak self] nudge in
            Task { @MainActor in
                self?.adjustSyncOffset(by: nudge)
            }
        }
    }

    func loadTrack(_ track: SubtitleTrack) {
        pause()
        currentTrack = track
        currentTime = 0
        syncOffsetSeconds = 0
        updateActiveCueForCurrentTime()
    }

    func importSRTFileContent(_ content: String, fileName: String, sourceLanguage: SourceLanguage) {
        let cues = SRTParser.parse(content: content)
        guard !cues.isEmpty else { return }
        let track = SubtitleTrack(
            id: UUID(),
            title: fileName,
            sourceLanguage: sourceLanguage,
            cues: cues
        )
        loadTrack(track)
    }

    /// Translates all cues in a foreign `.srt` file (e.g. Korean or Japanese) into English
    /// using the resilient failover chain: ChatGPT -> Gemini 3.8 -> Free Fallback.
    func translateLoadedTrackToEnglish() async {
        guard !isTranslatingTrack else { return }
        isTranslatingTrack = true
        translationProgress = 0.0
        defer { isTranslatingTrack = false }

        let total = max(1, currentTrack.cues.count)
        for index in currentTrack.cues.indices {
            let cue = currentTrack.cues[index]
            let sourceLine = cue.originalText ?? cue.translatedText
            let prevContext = index > 0 ? currentTrack.cues[index - 1].translatedText : nil

            let result = await TranslationService.shared.translateToEnglish(
                text: sourceLine,
                sourceLanguage: currentTrack.sourceLanguage,
                recentContext: prevContext
            )

            currentTrack.cues[index].originalText = sourceLine
            currentTrack.cues[index].translatedText = result.translatedText
            currentTrack.cues[index].providerUsed = result.provider.shortBadge
            translationProgress = Double(index + 1) / Double(total)
            updateActiveCueForCurrentTime()
        }
    }

    // MARK: - Playback Controls

    func togglePlayPause() {
        if isPlaying {
            pause()
        } else {
            play()
        }
    }

    func play() {
        guard !isPlaying else { return }
        isPlaying = true
        lastTickDate = Date()

        playbackTimer?.invalidate()
        let timer = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.tick()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        playbackTimer = timer
    }

    func pause() {
        isPlaying = false
        playbackTimer?.invalidate()
        playbackTimer = nil
        lastTickDate = nil
    }

    func seek(to time: TimeInterval) {
        currentTime = max(0, min(time, max(currentTrack.totalDuration, 1)))
        updateActiveCueForCurrentTime()
    }

    func adjustSyncOffset(by delta: TimeInterval) {
        syncOffsetSeconds = ((syncOffsetSeconds + delta) * 100).rounded() / 100
        updateActiveCueForCurrentTime()
    }

    private func tick() {
        guard isPlaying else { return }
        let now = Date()
        let delta = now.timeIntervalSince(lastTickDate ?? now)
        lastTickDate = now

        currentTime += delta
        if currentTime > currentTrack.totalDuration + 2.0 {
            // Loop demo track smoothly so user can test PiP continuously
            currentTime = 0
        }
        updateActiveCueForCurrentTime()
    }

    func updateActiveCueForCurrentTime() {
        let effectiveTime = max(0, currentTime + syncOffsetSeconds)
        let matched = currentTrack.cues.first { cue in
            effectiveTime >= cue.startTime && effectiveTime <= cue.endTime
        }

        activeCue = matched
        let offsetStr = String(format: "%+.2fs", syncOffsetSeconds)
        let badge = "\(currentTrack.sourceLanguage.flagEmoji) \(currentTrack.sourceLanguage.shortCode) → EN • \(SRTParser.formatTime(effectiveTime)) (Sync \(offsetStr))"

        if let matched {
            PiPSubtitleManager.shared.updateSubtitle(
                original: matched.originalText,
                english: matched.translatedText,
                badge: badge
            )
        } else {
            PiPSubtitleManager.shared.updateSubtitle(
                original: nil,
                english: "…",
                badge: badge
            )
        }
    }
}
