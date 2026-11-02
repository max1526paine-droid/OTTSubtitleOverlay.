import Combine
import Foundation

/// Drives synchronized subtitle playback in the floating PiP overlay.
@MainActor
final class SubtitleSyncEngine: ObservableObject {
    static let shared = SubtitleSyncEngine()

    @Published var currentTrack: SubtitleTrack
    @Published var isPlaying: Bool = false
    @Published var currentTime: TimeInterval = 0.0
    @Published var syncOffsetSeconds: TimeInterval = 0.0
    @Published var activeCue: SubtitleCue?

    private var playbackTimer: Timer?
    private var lastTickDate: Date?

    init() {
        self.currentTrack = SubtitleTrack(
            id: UUID(),
            title: "No Subtitle Loaded",
            cues: []
        )
        self.activeCue = nil

        // PiP overlay transport controls
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

        // Tapping ↺ 10 / ↻ 10 inside the floating PiP window jumps to Previous / Next dialogue line!
        PiPSubtitleManager.shared.onSkipRequested = { [weak self] seconds in
            Task { @MainActor in
                guard let self else { return }
                if seconds >= 0 {
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

        if startAtFirstDialogue && !track.cues.isEmpty {
            let idx = SRTParser.firstSpokenDialogueIndex(in: track.cues)
            currentTime = max(0, track.cues[idx].startTime)
        } else {
            currentTime = 0
        }
        updateActiveCueForCurrentTime()
    }

    func importSRTContent(_ content: String, title: String) {
        let cues = SRTParser.parse(content: content)
        guard !cues.isEmpty else { return }
        let track = SubtitleTrack(
            id: UUID(),
            title: title,
            cues: cues
        )
        loadTrack(track, startAtFirstDialogue: true)
    }

    // MARK: - Dialogue Navigation

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

    func jumpToStart() {
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
                text: "Search your show & episode below to load English subtitles",
                badge: "SubFloat • Ready"
            )
            return
        }

        let effectiveTime = max(0, currentTime + syncOffsetSeconds)

        // 1. Spoken line active right now
        if let matched = currentTrack.cues.first(where: { effectiveTime >= $0.startTime && effectiveTime <= $0.endTime }) {
            activeCue = matched
            let badge = "\(currentTrack.title) • \(SRTParser.formatTime(effectiveTime)) [\(matched.index)/\(currentTrack.cues.count)]"
            PiPSubtitleManager.shared.updateSubtitle(
                text: matched.text,
                badge: badge
            )
            return
        }

        // 2. Hold line for 1.8s for fast reading
        if let recent = currentTrack.cues.last(where: { $0.endTime < effectiveTime && (effectiveTime - $0.endTime) <= 1.8 }) {
            activeCue = recent
            let badge = "\(currentTrack.title) • \(SRTParser.formatTime(effectiveTime)) [\(recent.index)/\(currentTrack.cues.count)]"
            PiPSubtitleManager.shared.updateSubtitle(
                text: recent.text,
                badge: badge
            )
            return
        }

        // 3. During silent gaps, preview NEXT upcoming dialogue with countdown
        if let upcoming = currentTrack.cues.first(where: { $0.startTime > effectiveTime }) {
            activeCue = upcoming
            let waitSecs = max(1, Int(ceil(upcoming.startTime - effectiveTime)))
            let badge = "\(currentTrack.title) • \(SRTParser.formatTime(effectiveTime)) (Next in \(waitSecs)s)"
            PiPSubtitleManager.shared.updateSubtitle(
                text: "[\(SRTParser.formatTime(upcoming.startTime))] \(upcoming.text)",
                badge: badge
            )
            return
        }

        // 4. End of file
        activeCue = nil
        PiPSubtitleManager.shared.updateSubtitle(
            text: "End of episode subtitles.",
            badge: "\(currentTrack.title) • \(SRTParser.formatTime(effectiveTime))"
        )
    }
}
