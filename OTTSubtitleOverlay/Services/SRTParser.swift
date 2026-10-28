import Foundation

/// Parses standard `.srt` (SubRip) and `.vtt` (WebVTT) subtitle files into `SubtitleCue` arrays.
enum SRTParser {
    static func parse(content: String) -> [SubtitleCue] {
        let normalized = content
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

            // Find the timestamp line containing "-->"
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
                .joined(separator: "\n")
                .replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines)

            guard !cleanedText.isEmpty else { continue }

            // Optional dual-line detection if an SRT block has [Foreign] / [English] lines
            let cue = SubtitleCue(
                index: autoIndex,
                startTime: startTime,
                endTime: endTime,
                originalText: nil,
                translatedText: cleanedText
            )
            cues.append(cue)
            autoIndex += 1
        }

        return cues
    }

    private static func parseTimestamp(_ raw: String) -> TimeInterval? {
        // Supports "00:01:23,450" or "00:01:23.450" or "01:23.450"
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
