import Foundation
import SwiftUI

// MARK: - Subtitle Cue

struct SubtitleCue: Identifiable, Codable, Equatable {
    let id: UUID
    let index: Int
    let startTime: TimeInterval
    let endTime: TimeInterval
    var text: String

    init(
        id: UUID = UUID(),
        index: Int,
        startTime: TimeInterval,
        endTime: TimeInterval,
        text: String
    ) {
        self.id = id
        self.index = index
        self.startTime = startTime
        self.endTime = endTime
        self.text = text
    }
}

// MARK: - Subtitle Track

struct SubtitleTrack: Identifiable, Codable {
    let id: UUID
    var title: String
    var cues: [SubtitleCue]

    var totalDuration: TimeInterval {
        cues.map(\.endTime).max() ?? 0
    }
}

// MARK: - Search Result

struct SubtitleSearchResult: Identifiable {
    let id: String
    let title: String
    let releaseName: String
    let language: String
    let downloadCount: Int
    let downloadUrl: String?
    let season: Int?
    let episode: Int?
}
