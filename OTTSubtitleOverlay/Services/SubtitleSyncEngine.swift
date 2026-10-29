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
    @Published var isFetchingOnline: Bool = false
    @Published var onlineStatus: String = ""

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

        // Tapping +10 / -10 inside the floating PiP overlay over Netflix jumps to the Next / Previous dialogue line!
        PiPSubtitleManager.shared.onSkipRequested = { [weak self] direction in
            Task { @MainActor in
                guard let self else { return }
                if direction >= 0 {
                    self.skipToNextCue()
                } else {
                    self.skipToPreviousCue()
                }
            }
        }
    }

    func loadTrack(_ track: SubtitleTrack, startAtFirstDialogue: Bool = true) {
        pause()
        currentTrack = track
        syncOffsetSeconds = 0

        if startAtFirstDialogue, !track.cues.isEmpty {
            let firstIdx = SRTParser.firstSpokenDialogueIndex(in: track.cues)
            currentTime = max(0, track.cues[firstIdx].startTime)
        } else {
            currentTime = 0
        }
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
        loadTrack(track, startAtFirstDialogue: true)
    }

    // MARK: - Line-by-Line Jump Controls (Sync to Netflix in 1 Tap)

    func jumpToCue(_ cue: SubtitleCue) {
        syncOffsetSeconds = 0
        currentTime = max(0, cue.startTime + 0.05)
        if isPlaying {
            lastTickDate = Date()
        } else {
            play()
        }
        updateActiveCueForCurrentTime()
    }

    func jumpToStartOfEpisode() {
        syncOffsetSeconds = 0
        currentTime = 0
        if isPlaying {
            lastTickDate = Date()
        }
        updateActiveCueForCurrentTime()
    }

    func jumpToFirstDialogue() {
        guard !currentTrack.cues.isEmpty else { return }
        let idx = SRTParser.firstSpokenDialogueIndex(in: currentTrack.cues)
        jumpToCue(currentTrack.cues[idx])
    }

    func skipToNextCue() {
        guard !currentTrack.cues.isEmpty else { return }
        let effectiveNow = max(0, currentTime + syncOffsetSeconds)
        if let nextCue = currentTrack.cues.first(where: { $0.startTime > effectiveNow + 0.15 }) {
            currentTime = max(0, nextCue.startTime + 0.05 - syncOffsetSeconds)
        } else if let first = currentTrack.cues.first {
            currentTime = max(0, first.startTime + 0.05 - syncOffsetSeconds)
        }
        if isPlaying {
            lastTickDate = Date()
        }
        updateActiveCueForCurrentTime()
    }

    func skipToPreviousCue() {
        guard !currentTrack.cues.isEmpty else { return }
        let effectiveNow = max(0, currentTime + syncOffsetSeconds)
        if let prevCue = currentTrack.cues.last(where: { $0.startTime < effectiveNow - 1.2 }) {
            currentTime = max(0, prevCue.startTime + 0.05 - syncOffsetSeconds)
        } else if let first = currentTrack.cues.first {
            currentTime = max(0, first.startTime + 0.05 - syncOffsetSeconds)
        }
        if isPlaying {
            lastTickDate = Date()
        }
        updateActiveCueForCurrentTime()
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
        if isPlaying {
            lastTickDate = Date()
        }
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
            pause()
        }
        updateActiveCueForCurrentTime()
    }

    func updateActiveCueForCurrentTime() {
        guard !currentTrack.cues.isEmpty else {
            PiPSubtitleManager.shared.updateSubtitle(
                original: nil,
                english: "Search your show & episode below to load English subtitles",
                badge: "SubFloat OTT v3.0 • Ready"
            )
            return
        }

        let effectiveTime = max(0, currentTime + syncOffsetSeconds)

        // 1. Direct hit within a cue's [startTime, endTime]
        if let matched = currentTrack.cues.first(where: { effectiveTime >= $0.startTime && effectiveTime <= $0.endTime }) {
            activeCue = matched
            let badge = "\(currentTrack.title) • \(SRTParser.formatTime(effectiveTime)) [Line \(matched.index)/\(currentTrack.cues.count)]"
            PiPSubtitleManager.shared.updateSubtitle(
                original: matched.originalText,
                english: matched.translatedText,
                badge: badge
            )
            return
        }

        // 2. Hold the just-spoken cue for up to 1.8s so fast dialogue is easy to read
        if let recent = currentTrack.cues.last(where: { $0.endTime < effectiveTime && (effectiveTime - $0.endTime) <= 1.8 }) {
            activeCue = recent
            let badge = "\(currentTrack.title) • \(SRTParser.formatTime(effectiveTime)) [Line \(recent.index)/\(currentTrack.cues.count)]"
            PiPSubtitleManager.shared.updateSubtitle(
                original: recent.originalText,
                english: recent.translatedText,
                badge: badge
            )
            return
        }

        // 3. During longer silent gaps, preview the NEXT upcoming line with its timestamp
        // so the PiP window never looks blank or frozen!
        if let upcoming = currentTrack.cues.first(where: { $0.startTime > effectiveTime }) {
            activeCue = upcoming
            let waitSecs = max(1, Int(ceil(upcoming.startTime - effectiveTime)))
            let badge = "\(currentTrack.title) • \(SRTParser.formatTime(effectiveTime)) (Next in \(waitSecs)s)"
            PiPSubtitleManager.shared.updateSubtitle(
                original: nil,
                english: "[\(SRTParser.formatTime(upcoming.startTime))] \(upcoming.translatedText)",
                badge: badge
            )
            return
        }

        // 4. End of track
        activeCue = nil
        PiPSubtitleManager.shared.updateSubtitle(
            original: nil,
            english: "End of episode subtitles.",
            badge: "\(currentTrack.title) • \(SRTParser.formatTime(effectiveTime))"
        )
    }
}
