import AVFoundation
import Combine
import Speech
import UIKit

/// Manages real-time speech capture (via Microphone, Gemini 3.8 Live WebSocket, or ReplayKit System Audio Broadcast)
/// and translates Korean, Japanese, and other languages into English subtitles rendered in the floating PiP window.
@MainActor
final class LiveAudioTranslator: ObservableObject {
    static let shared = LiveAudioTranslator()

    @Published var sourceLanguage: SourceLanguage = .korean {
        didSet {
            UserDefaults(suiteName: AppGroupConfig.suiteName)?
                .set(sourceLanguage.rawValue, forKey: AppGroupConfig.selectedLanguageKey)
            if isListening {
                restartListeningForNewLanguage()
            }
        }
    }

    @Published var isListening: Bool = false
    @Published var isBroadcastActive: Bool = false
    @Published var liveOriginalText: String = ""
    @Published var liveTranslatedText: String = ""
    @Published var liveHistory: [SubtitleCue] = []
    @Published var statusMessage: String = "Ready to listen & translate"

    private let audioEngine = AVAudioEngine()
    private var speechRecognizer: SFSpeechRecognizer?
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    private var sessionRotationTimer: Timer?
    private var appGroupPollTimer: Timer?
    private var debounceTranslationTask: Task<Void, Never>?
    private var lastTranslatedSourceSnippet: String = ""
    private var lastAppGroupTimestamp: Double = 0

    private let geminiLiveSocket = GeminiLiveWebSocketClient()

    init() {
        setupAppGroupObserver()
        setupGeminiLiveCallbacks()
    }

    // MARK: - Permissions & Start/Stop

    func toggleListening() {
        if isListening {
            stopListening()
        } else {
            Task {
                await requestPermissionsAndStart()
            }
        }
    }

    func requestPermissionsAndStart() async {
        let speechStatus = await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { status in
                continuation.resume(returning: status)
            }
        }

        let micGranted = await withCheckedContinuation { continuation in
            AVAudioSession.sharedInstance().requestRecordPermission { granted in
                continuation.resume(returning: granted)
            }
        }

        guard micGranted else {
            statusMessage = "Microphone permission is required for Live Audio mode."
            return
        }

        if speechStatus != .authorized && TranslationService.shared.failoverOrder != .geminiLiveDirectAudio {
            statusMessage = "Speech recognition permission is required."
            return
        }

        startListeningSession()
    }

    private func startListeningSession() {
        stopInternalAudioPipeline()

        // Configure AudioSession with .mixWithOthers so Netflix / Prime Video keeps playing!
        PiPSubtitleManager.shared.configureAudioSessionForOTTCoexistence(enableMicCapture: true)

        let translationService = TranslationService.shared
        let useGeminiLiveSocket = (
            translationService.failoverOrder == .geminiLiveDirectAudio &&
            !translationService.geminiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
            !translationService.gemini38QuotaExhausted
        )

        if useGeminiLiveSocket {
            geminiLiveSocket.connect(
                apiKey: translationService.geminiKey,
                targetLanguageCode: "en",
                useLive38Agent: false
            )
            statusMessage = "Streaming to Gemini Live Translate (\(sourceLanguage.shortCode) → EN)..."
        } else {
            setupAppleSpeechRecognizer()
            statusMessage = "Listening (\(sourceLanguage.flagEmoji) \(sourceLanguage.shortCode) → EN via \(translationService.activeProvider.shortBadge))..."
        }

        do {
            let inputNode = audioEngine.inputNode
            let recordingFormat = inputNode.outputFormat(forBus: 0)
            inputNode.removeTap(onBus: 0)

            inputNode.installTap(onBus: 0, bufferSize: 2048, format: recordingFormat) { [weak self] buffer, _ in
                guard let self else { return }
                self.recognitionRequest?.append(buffer)
                if useGeminiLiveSocket, let pcm16k = Self.convertBufferToPCM16kMono(buffer) {
                    self.geminiLiveSocket.sendPCM16kAudioChunk(pcm16k)
                }
            }

            audioEngine.prepare()
            try audioEngine.start()
            isListening = true

            // Automatically rotate SpeechRecognition session every 50s so iOS 60s limit never stops movie translation
            sessionRotationTimer = Timer.scheduledTimer(withTimeInterval: 50.0, repeats: true) { [weak self] _ in
                Task { @MainActor in
                    guard let self, self.isListening else { return }
                    self.rotateSpeechRecognitionTaskIfNeeded()
                }
            }
            if let sessionRotationTimer {
                RunLoop.main.add(sessionRotationTimer, forMode: .common)
            }
        } catch {
            statusMessage = "Audio Engine failed: \(error.localizedDescription)"
            isListening = false
        }
    }

    private func setupAppleSpeechRecognizer() {
        let locale = Locale(identifier: sourceLanguage.rawValue)
        speechRecognizer = SFSpeechRecognizer(locale: locale)

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        if #available(iOS 16.0, *) {
            request.addsPunctuation = true
        }
        self.recognitionRequest = request

        recognitionTask = speechRecognizer?.recognitionTask(with: request) { [weak self] result, error in
            guard let self else { return }
            Task { @MainActor in
                if let result {
                    let fullTranscript = result.bestTranscription.formattedString
                    let recentClause = Self.extractRecentClause(from: fullTranscript)
                    self.handleRecognizedSourceSpeech(recentClause, isFinal: result.isFinal)
                }
                if error != nil && self.isListening {
                    self.rotateSpeechRecognitionTaskIfNeeded()
                }
            }
        }
    }

    private func rotateSpeechRecognitionTaskIfNeeded() {
        guard isListening, TranslationService.shared.failoverOrder != .geminiLiveDirectAudio else { return }
        recognitionTask?.cancel()
        recognitionRequest?.endAudio()
        setupAppleSpeechRecognizer()
    }

    private func restartListeningForNewLanguage() {
        stopListening()
        startListeningSession()
    }

    func stopListening() {
        isListening = false
        stopInternalAudioPipeline()
        PiPSubtitleManager.shared.configureAudioSessionForOTTCoexistence(enableMicCapture: false)
        statusMessage = "Paused"
    }

    private func stopInternalAudioPipeline() {
        sessionRotationTimer?.invalidate()
        sessionRotationTimer = nil
        debounceTranslationTask?.cancel()
        if audioEngine.isRunning {
            audioEngine.stop()
            audioEngine.inputNode.removeTap(onBus: 0)
        }
        recognitionRequest?.endAudio()
        recognitionRequest = nil
        recognitionTask?.cancel()
        recognitionTask = nil
        geminiLiveSocket.disconnect()
    }

    // MARK: - Translation Pipeline (ChatGPT -> Gemini 3.8 -> Free Fallback)

    private func handleRecognizedSourceSpeech(_ clause: String, isFinal: Bool) {
        let trimmed = clause.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        liveOriginalText = trimmed
        let srtOverride = SubtitleSyncEngine.shared.srtOverrideActive
        if !srtOverride {
            PiPSubtitleManager.shared.updateSubtitle(
                original: trimmed,
                english: liveTranslatedText.isEmpty ? "Translating..." : liveTranslatedText,
                badge: "\(sourceLanguage.flagEmoji) \(sourceLanguage.shortCode) → EN • \(TranslationService.shared.activeProvider.shortBadge)"
            )
        }

        guard trimmed != lastTranslatedSourceSnippet else { return }

        debounceTranslationTask?.cancel()
        let delayNanoseconds: UInt64 = isFinal ? 50_000_000 : 380_000_000
        debounceTranslationTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: delayNanoseconds)
            guard !Task.isCancelled, let self else { return }

            self.lastTranslatedSourceSnippet = trimmed
            let recentContext = self.liveHistory.first?.translatedText
            let result = await TranslationService.shared.translateToEnglish(
                text: trimmed,
                sourceLanguage: self.sourceLanguage,
                recentContext: recentContext
            )

            guard !Task.isCancelled else { return }
            self.liveTranslatedText = result.translatedText

            // When real SRT subtitles are active, use the live translation only to keep the SRT clock in sync
            if SubtitleSyncEngine.shared.srtOverrideActive {
                SubtitleSyncEngine.shared.autoAlign(withEnglishLine: result.translatedText)
                return
            }

            let badge = "\(self.sourceLanguage.flagEmoji) \(self.sourceLanguage.shortCode) → EN • \(result.provider.shortBadge)"
            PiPSubtitleManager.shared.updateSubtitle(
                original: trimmed,
                english: result.translatedText,
                badge: badge
            )

            if result.didFailover, let reason = result.failoverReason {
                self.statusMessage = "Failover active: \(reason)"
            } else {
                self.statusMessage = "Live (\(result.provider.shortBadge))"
            }

            self.appendHistoryCue(
                original: trimmed,
                translated: result.translatedText,
                provider: result.provider.shortBadge
            )
        }
    }

    private func setupGeminiLiveCallbacks() {
        geminiLiveSocket.onTranscriptReceived = { [weak self] original, translated in
            Task { @MainActor in
                guard let self else { return }
                if let original {
                    self.liveOriginalText = original
                }
                self.liveTranslatedText = translated
                let badge = "\(self.sourceLanguage.flagEmoji) \(self.sourceLanguage.shortCode) → EN • Gemini 3.8 Live"
                PiPSubtitleManager.shared.updateSubtitle(
                    original: self.liveOriginalText,
                    english: translated,
                    badge: badge
                )
                self.appendHistoryCue(
                    original: self.liveOriginalText,
                    translated: translated,
                    provider: "Gemini 3.8 Live"
                )
            }
        }

        geminiLiveSocket.onSessionDisconnected = { [weak self] _ in
            Task { @MainActor in
                guard let self, self.isListening else { return }
                // Failover from Gemini Live WebSocket to SpeechRecognizer + ChatGPT/Gemini 3.8 REST chain
                self.statusMessage = "Gemini Live stream ended — failing over to ChatGPT / Gemini 3.8 REST..."
                self.setupAppleSpeechRecognizer()
            }
        }
    }

    private func appendHistoryCue(original: String?, translated: String, provider: String) {
        if let first = liveHistory.first, first.originalText == original {
            liveHistory[0].translatedText = translated
            liveHistory[0].providerUsed = provider
            return
        }
        let cue = SubtitleCue(
            index: liveHistory.count + 1,
            startTime: Date().timeIntervalSince1970,
            endTime: Date().timeIntervalSince1970 + 3,
            originalText: original,
            translatedText: translated,
            providerUsed: provider
        )
        liveHistory.insert(cue, at: 0)
        if liveHistory.count > 60 {
            liveHistory.removeLast()
        }
    }

    // MARK: - ReplayKit Broadcast Extension Shared App Group Listener

    private func setupAppGroupObserver() {
        let timer = Timer(timeInterval: 0.4, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.pollSharedBroadcastGroup()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.appGroupPollTimer = timer
    }

    private func pollSharedBroadcastGroup() {
        guard let defaults = UserDefaults(suiteName: AppGroupConfig.suiteName) else { return }
        let active = defaults.bool(forKey: AppGroupConfig.broadcastActiveKey)
        if isBroadcastActive != active {
            isBroadcastActive = active
        }

        let timestamp = defaults.double(forKey: AppGroupConfig.latestTimestampKey)
        guard timestamp > lastAppGroupTimestamp else { return }
        lastAppGroupTimestamp = timestamp

        let orig = defaults.string(forKey: AppGroupConfig.latestOriginalTextKey) ?? ""
        let trans = defaults.string(forKey: AppGroupConfig.latestTranslatedTextKey) ?? ""
        let provider = defaults.string(forKey: AppGroupConfig.latestProviderKey) ?? "ReplayKit AI"

        if !orig.isEmpty && trans.isEmpty {
            // Broadcast extension sent raw recognized foreign text; translate via our failover chain
            handleRecognizedSourceSpeech(orig, isFinal: true)
        } else if !trans.isEmpty {
            liveOriginalText = orig
            liveTranslatedText = trans
            PiPSubtitleManager.shared.updateSubtitle(
                original: orig,
                english: trans,
                badge: "\(sourceLanguage.flagEmoji) \(sourceLanguage.shortCode) → EN • \(provider)"
            )
            appendHistoryCue(original: orig, translated: trans, provider: provider)
        }
    }

    // MARK: - Helpers

    private static func extractRecentClause(from fullText: String) -> String {
        let words = fullText.split(separator: " ")
        if words.count <= 14 {
            return fullText
        }
        return words.suffix(14).joined(separator: " ")
    }

    /// Converts an `AVAudioPCMBuffer` into 16kHz, 16-bit mono PCM `Data` (`audio/pcm;rate=16000`) for Gemini Live API.
    private static func convertBufferToPCM16kMono(_ buffer: AVAudioPCMBuffer) -> Data? {
        guard let targetFormat = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: 16000,
            channels: 1,
            interleaved: true
        ),
        let converter = AVAudioConverter(from: buffer.format, to: targetFormat) else {
            return nil
        }

        let ratio = 16000.0 / buffer.format.sampleRate
        let targetFrameCapacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 16
        guard let outputBuffer = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: targetFrameCapacity) else {
            return nil
        }

        var error: NSError?
        var hasProvidedData = false
        let inputBlock: AVAudioConverterInputBlock = { _, outStatus in
            if hasProvidedData {
                outStatus.pointee = .noDataNow
                return nil
            }
            hasProvidedData = true
            outStatus.pointee = .haveData
            return buffer
        }

        converter.convert(to: outputBuffer, error: &error, withInputFrom: inputBlock)
        guard error == nil,
              let int16Channel = outputBuffer.int16ChannelData else {
            return nil
        }

        let byteCount = Int(outputBuffer.frameLength) * MemoryLayout<Int16>.size
        return Data(bytes: int16Channel[0], count: byteCount)
    }
}
