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
    @Published var isFetchingOnline: Bool = false
    @Published var onlineStatus: String = ""
    /// True while a downloaded real `.srt` drives the PiP bar instead of live AI translation.
    @Published var srtOverrideActive: Bool = false

    private var playbackTimer: Timer?
    private var lastTickDate: Date?

    init() {
        let emptyTrack = SubtitleTrack(
            id: UUID(),
            title: "No Subtitle Loaded",
            sourceLanguage: .korean,
            cues: []
        )
        self.currentTrack = emptyTrack
        self.activeCue = nil

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

    // MARK: - Online SRT Fallback (search + download real subtitles for the show)

    /// Searches OpenSubtitles, downloads the real `.srt` for the show, loads it and starts the PiP overlay.
    /// While active, live AI translations are only used to keep the subtitle clock aligned with the show.
    func findAndPlaySRT(query: String, season: String, episode: String, sourceLanguage: SourceLanguage) async {
        guard !isFetchingOnline else { return }
        isFetchingOnline = true
        defer { isFetchingOnline = false }

        guard let found = await OpenSubtitlesService.shared.autoScourAndDownload(
            query: query,
            season: season,
            episode: episode
        ) else {
            onlineStatus = OpenSubtitlesService.shared.statusMessage
            return
        }

        let isEnglish = found.languageCode.lowercased().hasPrefix("en")
        let track = SubtitleTrack(
            id: UUID(),
            title: found.title,
            sourceLanguage: sourceLanguage,
            cues: found.cues
        )
        loadTrack(track)
        srtOverrideActive = true
        play()
        PiPSubtitleManager.shared.startPiPIfNeeded()

        if isEnglish {
            onlineStatus = "Playing real English subtitles for \"\(found.title)\" (\(found.cues.count) lines). Say a line or tap the sync buttons to align."
        } else {
            onlineStatus = "No English file found. Translating \(found.languageCode.uppercased()) subtitles to English..."
            await translateLoadedTrackToEnglish()
            onlineStatus = "Playing translated subtitles for \"\(found.title)\"."
        }
    }

    /// Stops the SRT override so live AI translation drives the PiP bar again.
    func stopSRTOverride() {
        srtOverrideActive = false
        pause()
        onlineStatus = "Back to live AI translation."
    }

    /// Aligns the subtitle clock by fuzzy-matching a live English line (translated from the audio)
    /// against the downloaded SRT cues.
    func autoAlign(withEnglishLine line: String) {
        guard srtOverrideActive else { return }
        let target = Self.wordTokens(line)
        guard target.count >= 3 else { return }

        let effectiveNow = max(0, currentTime + syncOffsetSeconds)
        var bestIndex: Int?
        var bestScore: Double = 0

        for (index, cue) in currentTrack.cues.enumerated() {
            let cueTokens = Self.wordTokens(cue.translatedText)
            guard !cueTokens.isEmpty else { continue }
            let overlap = Double(target.intersection(cueTokens).count) / Double(min(target.count, cueTokens.count))
            // Prefer cues closest to the current clock when scores tie
            let proximityPenalty = min(abs(cue.startTime - effectiveNow) / 100_000.0, 0.05)
            let score = overlap - proximityPenalty
            if score > bestScore {
                bestScore = score
                bestIndex = index
            }
        }

        guard let bestIndex, bestScore >= 0.6 else { return }
        let cue = currentTrack.cues[bestIndex]
        currentTime = max(0, cue.startTime + 0.5 - syncOffsetSeconds)
        if isPlaying {
            lastTickDate = Date()
        }
        updateActiveCueForCurrentTime()
    }

    private static func wordTokens(_ text: String) -> Set<String> {
        let parts = text.lowercased().components(separatedBy: CharacterSet.alphanumerics.inverted)
        return Set(parts.filter { $0.count > 2 })
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
        guard !currentTrack.cues.isEmpty else {
            PiPSubtitleManager.shared.updateSubtitle(
                original: nil,
                english: "Search any movie or show to begin subtitles",
                badge: "SubFloat OTT • Ready"
            )
            return
        }
        let effectiveTime = max(0, currentTime + syncOffsetSeconds)
        let matched = currentTrack.cues.first { cue in
            effectiveTime >= cue.startTime && effectiveTime <= cue.endTime
        }

        activeCue = matched
        let offsetStr = String(format: "%+.2fs", syncOffsetSeconds)
        let badge = "\(currentTrack.title) • \(SRTParser.formatTime(effectiveTime)) (\(offsetStr))"

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
