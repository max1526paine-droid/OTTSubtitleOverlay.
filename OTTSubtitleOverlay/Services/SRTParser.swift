import Foundation

/// Fast, clean parser for .srt (SubRip) and .vtt (WebVTT) subtitle files.
/// Automatically cleans promotional ads and watermarks.
enum SRTParser {
    private static let adKeywords: [String] = [
        "opensubtitles",
        "osdb.link",
        "advertise your product",
        "do you want subtitles",
        "watch online movies",
        "support us and become vip",
        "become vip member",
        "subtitles by",
        "synced and corrected"
    ]

    static func parse(content: String) -> [SubtitleCue] {
        let normalized = content
            .replacingOccurrences(of: "\u{FEFF}", with: "")
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")

        let blocks = normalized.components(separatedBy: "\n\n")
        var cues: [SubtitleCue] = []
        var autoIndex = 1

        for rawBlock in blocks {
            let lines = rawBlock
                .components(separatedBy: "\n")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty && !$0.hasPrefix("WEBVTT") && !$0.hasPrefix("NOTE") }

            guard !lines.isEmpty else { continue }

            guard let timingLineIndex = lines.firstIndex(where: { $0.contains("-->") }) else {
                continue
            }

            let timingLine = lines[timingLineIndex]
            let parts = timingLine.components(separatedBy: "-->")
            guard parts.count == 2,
                  let startTime = parseTimestamp(parts[0]),
                  let endTime = parseTimestamp(parts[1]) else {
                continue
            }

            let textLines = lines.suffix(from: timingLineIndex + 1)
            let cleanedText = textLines
                .joined(separator: " ")
                .replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
                .replacingOccurrences(of: "\\{\\\\[^}]+\\}", with: "", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines)

            guard !cleanedText.isEmpty else { continue }

            let lower = cleanedText.lowercased()
            if adKeywords.contains(where: { lower.contains($0) }) {
                continue
            }

            let cue = SubtitleCue(
                index: autoIndex,
                startTime: startTime,
                endTime: endTime,
                text: cleanedText
            )
            cues.append(cue)
            autoIndex += 1
        }

        return cues
    }

    /// Finds index of the first dialogue line, skipping isolated intro title cards if followed by a long silent gap (>15s).
    static func firstSpokenDialogueIndex(in cues: [SubtitleCue]) -> Int {
        guard cues.count > 1 else { return 0 }
        for i in 0..<min(5, cues.count - 1) {
            let current = cues[i]
            let next = cues[i + 1]
            let gap = next.startTime - current.endTime
            let isAllCaps = (current.text == current.text.uppercased()) && current.text.count > 3
            if gap <= 15.0 && !isAllCaps {
                return i
            }
        }
        return 0
    }

    private static func parseTimestamp(_ raw: String) -> TimeInterval? {
        let token = raw
            .trimmingCharacters(in: .whitespaces)
            .components(separatedBy: " ").first ?? ""

        let normalized = token.replacingOccurrences(of: ",", with: ".")
        let components = normalized.components(separatedBy: ":")

        switch components.count {
        case 3:
            guard let hours = Double(components[0]),
                  let minutes = Double(components[1]),
                  let seconds = Double(components[2]) else { return nil }
            return (hours * 3600.0) + (minutes * 60.0) + seconds
        case 2:
            guard let minutes = Double(components[0]),
                  let seconds = Double(components[1]) else { return nil }
            return (minutes * 60.0) + seconds
        default:
            return nil
        }
    }

    static func formatTime(_ seconds: TimeInterval) -> String {
        let clamped = max(0, Int(seconds))
        let hrs = clamped / 3600
        let mins = (clamped % 3600) / 60
        let secs = clamped % 60
        if hrs > 0 {
            return String(format: "%d:%02d:%02d", hrs, mins, secs)
        }
        return String(format: "%02d:%02d", mins, secs)
    }
}
