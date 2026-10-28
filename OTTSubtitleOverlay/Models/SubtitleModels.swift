import Foundation
import SwiftUI

// MARK: - Supported Source Languages

enum SourceLanguage: String, CaseIterable, Identifiable, Codable {
    case korean = "ko-KR"
    case japanese = "ja-JP"
    case mandarin = "zh-CN"
    case spanish = "es-ES"
    case hindi = "hi-IN"
    case french = "fr-FR"
    case german = "de-DE"
    case thai = "th-TH"
    case turkish = "tr-TR"
    case portuguese = "pt-BR"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .korean: return "Korean (한국어)"
        case .japanese: return "Japanese (日本語)"
        case .mandarin: return "Chinese (中文)"
        case .spanish: return "Spanish (Español)"
        case .hindi: return "Hindi (हिन्दी)"
        case .french: return "French (Français)"
        case .german: return "German (Deutsch)"
        case .thai: return "Thai (ไทย)"
        case .turkish: return "Turkish (Türkçe)"
        case .portuguese: return "Portuguese (Português)"
        }
    }

    var shortCode: String {
        switch self {
        case .korean: return "KO"
        case .japanese: return "JA"
        case .mandarin: return "ZH"
        case .spanish: return "ES"
        case .hindi: return "HI"
        case .french: return "FR"
        case .german: return "DE"
        case .thai: return "TH"
        case .turkish: return "TR"
        case .portuguese: return "PT"
        }
    }

    var flagEmoji: String {
        switch self {
        case .korean: return "🇰🇷"
        case .japanese: return "🇯🇵"
        case .mandarin: return "🇨🇳"
        case .spanish: return "🇪🇸"
        case .hindi: return "🇮🇳"
        case .french: return "🇫🇷"
        case .german: return "🇩🇪"
        case .thai: return "🇹🇭"
        case .turkish: return "🇹🇷"
        case .portuguese: return "🇧🇷"
        }
    }

    var iso639Code: String {
        String(rawValue.prefix(2))
    }
}

// MARK: - AI Translation Provider & Failover Chain

enum AIProvider: String, CaseIterable, Identifiable, Codable {
    case chatGPT = "ChatGPT (gpt-4o-mini)"
    case gemini38 = "Gemini 3.8 (gemini-3.8-flash)"
    case geminiLive = "Gemini 3.8 Live Stream"
    case freeFallback = "Free Keyless Translator"

    var id: String { rawValue }

    var shortBadge: String {
        switch self {
        case .chatGPT: return "ChatGPT"
        case .gemini38: return "Gemini 3.8"
        case .geminiLive: return "Gemini 3.8 Live"
        case .freeFallback: return "Free API"
        }
    }

    var badgeColor: Color {
        switch self {
        case .chatGPT: return .green
        case .gemini38: return .blue
        case .geminiLive: return .purple
        case .freeFallback: return .orange
        }
    }
}

enum TranslationFailoverOrder: String, CaseIterable, Identifiable, Codable {
    case chatGPTThenGemini38 = "ChatGPT → Gemini 3.8 → Free Fallback"
    case gemini38ThenChatGPT = "Gemini 3.8 → ChatGPT → Free Fallback"
    case geminiLiveDirectAudio = "Gemini 3.8 Live Audio WebSocket → ChatGPT → Gemini 3.8"

    var id: String { rawValue }
}

// MARK: - Subtitle Mode

enum SubtitleSourceMode: String, CaseIterable, Identifiable {
    case liveAI = "Live AI Audio"
    case srtSync = "SRT / Search Sync"

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .liveAI: return "waveform.badge.mic"
        case .srtSync: return "captions.bubble.fill"
        }
    }
}

// MARK: - Subtitle Cue (for SRT / VTT & Live Feed)

struct SubtitleCue: Identifiable, Codable, Equatable {
    let id: UUID
    let index: Int
    let startTime: TimeInterval
    let endTime: TimeInterval
    var originalText: String?
    var translatedText: String
    var providerUsed: String?

    init(
        id: UUID = UUID(),
        index: Int,
        startTime: TimeInterval,
        endTime: TimeInterval,
        originalText: String? = nil,
        translatedText: String,
        providerUsed: String? = nil
    ) {
        self.id = id
        self.index = index
        self.startTime = startTime
        self.endTime = endTime
        self.originalText = originalText
        self.translatedText = translatedText
        self.providerUsed = providerUsed
    }
}

// MARK: - Subtitle Track

struct SubtitleTrack: Identifiable, Codable {
    let id: UUID
    var title: String
    var sourceLanguage: SourceLanguage
    var cues: [SubtitleCue]

    var totalDuration: TimeInterval {
        cues.map(\.endTime).max() ?? 0
    }
}

// MARK: - PiP Appearance Settings

enum SubtitleTextColor: String, CaseIterable, Identifiable, Codable {
    case white = "White"
    case cinemaYellow = "Cinema Yellow"
    case cyan = "Soft Cyan"
    case green = "Mint Green"

    var id: String { rawValue }

    var uiColor: UIColor {
        switch self {
        case .white: return .white
        case .cinemaYellow: return UIColor(red: 1.0, green: 0.92, blue: 0.23, alpha: 1.0)
        case .cyan: return UIColor(red: 0.40, green: 0.90, blue: 1.0, alpha: 1.0)
        case .green: return UIColor(red: 0.45, green: 0.98, blue: 0.65, alpha: 1.0)
        }
    }

    var swiftUIColor: Color {
        Color(uiColor)
    }
}

struct SubtitleStyleSettings: Codable, Equatable {
    var fontSize: CGFloat = 28.0
    var showOriginalLanguageLine: Bool = true
    var textColor: SubtitleTextColor = .cinemaYellow
    var backgroundOpacity: CGFloat = 0.88
    var showStatusHeaderInPiP: Bool = true
    var keepActiveWhenLockedOrBackgrounded: Bool = true
}

// MARK: - OTT App Quick Launch

struct OTTAppShortcut: Identifiable {
    let id = UUID()
    let name: String
    let urlScheme: String
    let fallbackWebURL: String
    let accentColor: Color
    let systemIcon: String

    static let supportedApps: [OTTAppShortcut] = [
        OTTAppShortcut(
            name: "Netflix",
            urlScheme: "nflx://",
            fallbackWebURL: "https://www.netflix.com",
            accentColor: .red,
            systemIcon: "play.tv.fill"
        ),
        OTTAppShortcut(
            name: "Prime Video",
            urlScheme: "aiv://",
            fallbackWebURL: "https://www.primevideo.com",
            accentColor: .blue,
            systemIcon: "film.fill"
        ),
        OTTAppShortcut(
            name: "Crunchyroll",
            urlScheme: "crunchyroll://",
            fallbackWebURL: "https://www.crunchyroll.com",
            accentColor: .orange,
            systemIcon: "sparkles.tv.fill"
        ),
        OTTAppShortcut(
            name: "Disney+",
            urlScheme: "disneyplus://",
            fallbackWebURL: "https://www.disneyplus.com",
            accentColor: .indigo,
            systemIcon: "tv.and.mediabox.fill"
        ),
        OTTAppShortcut(
            name: "Viki",
            urlScheme: "viki://",
            fallbackWebURL: "https://www.viki.com",
            accentColor: .purple,
            systemIcon: "captions.bubble"
        )
    ]
}

// MARK: - Shared App Group Constants

enum AppGroupConfig {
    static let suiteName = "group.com.irshad.ottsubtitleoverlay"
    static let latestOriginalTextKey = "latest_original_text"
    static let latestTranslatedTextKey = "latest_translated_text"
    static let latestProviderKey = "latest_provider_used"
    static let latestTimestampKey = "latest_timestamp"
    static let broadcastActiveKey = "broadcast_active"
    static let selectedLanguageKey = "selected_source_language"
    static let openaiKeyStorage = "openai_api_key"
    static let geminiKeyStorage = "gemini_api_key"
    static let failoverOrderStorage = "translation_failover_order"
    static let darwinNotificationName = "com.irshad.ottsubtitleoverlay.subtitleUpdated"
}
