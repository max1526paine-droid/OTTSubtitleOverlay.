import CoreMedia
import ReplayKit
import Speech

/// ReplayKit Broadcast Upload Extension that captures system audio (`.audioApp`) directly
/// from OTT apps, transcribes foreign speech (Korean, Japanese, etc.), and shares it with
/// the main app's PiP subtitle overlay via App Groups.
final class SampleHandler: RPBroadcastSampleHandler {
    private let suiteName = "group.com.irshad.ottsubtitleoverlay"
    private var speechRecognizer: SFSpeechRecognizer?
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    private var lastPublishedSnippet: String = ""

    override func broadcastStarted(withSetupInfo setupInfo: [String: NSObject]?) {
        let defaults = UserDefaults(suiteName: suiteName)
        defaults?.set(true, forKey: "broadcast_active")

        let langCode = defaults?.string(forKey: "selected_source_language") ?? "ko-KR"
        startRecognition(localeIdentifier: langCode)
    }

    override func broadcastPaused() {
        recognitionRequest?.endAudio()
    }

    override func broadcastResumed() {
        let defaults = UserDefaults(suiteName: suiteName)
        let langCode = defaults?.string(forKey: "selected_source_language") ?? "ko-KR"
        startRecognition(localeIdentifier: langCode)
    }

    override func broadcastFinished() {
        let defaults = UserDefaults(suiteName: suiteName)
        defaults?.set(false, forKey: "broadcast_active")
        recognitionTask?.cancel()
        recognitionRequest?.endAudio()
    }

    override func processSampleBuffer(_ sampleBuffer: CMSampleBuffer, with sampleBufferType: RPSampleBufferType) {
        switch sampleBufferType {
        case .audioApp:
            // System audio directly from the foreground app
            recognitionRequest?.appendAudioSampleBuffer(sampleBuffer)
        case .audioMic:
            break
        case .video:
            break
        @unknown default:
            break
        }
    }

    private func startRecognition(localeIdentifier: String) {
        recognitionTask?.cancel()
        recognitionRequest?.endAudio()

        speechRecognizer = SFSpeechRecognizer(locale: Locale(identifier: localeIdentifier))
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        if #available(iOS 16.0, *) {
            request.addsPunctuation = true
        }
        self.recognitionRequest = request

        recognitionTask = speechRecognizer?.recognitionTask(with: request) { [weak self] result, error in
            guard let self else { return }
            if let result {
                let fullText = result.bestTranscription.formattedString
                let words = fullText.split(separator: " ")
                let recent = words.count <= 14 ? fullText : words.suffix(14).joined(separator: " ")
                self.publishRecognizedSnippet(recent)
            }
            if error != nil {
                self.startRecognition(localeIdentifier: localeIdentifier)
            }
        }
    }

    private func publishRecognizedSnippet(_ snippet: String) {
        let trimmed = snippet.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != lastPublishedSnippet else { return }
        lastPublishedSnippet = trimmed

        guard let defaults = UserDefaults(suiteName: suiteName) else { return }
        defaults.set(trimmed, forKey: "latest_original_text")
        defaults.set("", forKey: "latest_translated_text")
        defaults.set(Date().timeIntervalSince1970, forKey: "latest_timestamp")
    }
}
