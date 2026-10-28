import CoreMedia
import Foundation
import ReplayKit
import Speech

/// ReplayKit Broadcast Upload Extension that captures system audio (`.audioApp`) directly
/// from OTT apps, transcribes foreign speech (Korean, Japanese, etc.), and shares it with
/// the main app's PiP subtitle overlay via both Loopback HTTP (`127.0.0.1:49876`, works on Free Apple ID)
/// and App Groups (`UserDefaults`).
final class SampleHandler: RPBroadcastSampleHandler {
    private let suiteName = "group.com.irshad.ottsubtitleoverlay"
    private let localBridgePort = 49876
    private var speechRecognizer: SFSpeechRecognizer?
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    private var lastPublishedSnippet: String = ""
    private var currentLocaleIdentifier: String = "ko-KR"

    override func broadcastStarted(withSetupInfo setupInfo: [String: NSObject]?) {
        let defaults = UserDefaults(suiteName: suiteName)
        defaults?.set(true, forKey: "broadcast_active")

        let langCode = defaults?.string(forKey: "selected_source_language") ?? "ko-KR"
        currentLocaleIdentifier = langCode
        startRecognition(localeIdentifier: langCode)
        sendLoopbackUpdate(active: true, snippet: "")
    }

    override func broadcastPaused() {
        recognitionRequest?.endAudio()
    }

    override func broadcastResumed() {
        startRecognition(localeIdentifier: currentLocaleIdentifier)
    }

    override func broadcastFinished() {
        let defaults = UserDefaults(suiteName: suiteName)
        defaults?.set(false, forKey: "broadcast_active")
        sendLoopbackUpdate(active: false, snippet: "")
        recognitionTask?.cancel()
        recognitionRequest?.endAudio()
    }

    override func processSampleBuffer(_ sampleBuffer: CMSampleBuffer, with sampleBufferType: RPSampleBufferType) {
        switch sampleBufferType {
        case .audioApp:
            // System audio directly from the foreground app (Netflix / Prime Video / YouTube)
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
                self.startRecognition(localeIdentifier: self.currentLocaleIdentifier)
            }
        }
    }

    private func publishRecognizedSnippet(_ snippet: String) {
        let trimmed = snippet.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != lastPublishedSnippet else { return }
        lastPublishedSnippet = trimmed

        if let defaults = UserDefaults(suiteName: suiteName) {
            defaults.set(trimmed, forKey: "latest_original_text")
            defaults.set("", forKey: "latest_translated_text")
            defaults.set(Date().timeIntervalSince1970, forKey: "latest_timestamp")
        }
        sendLoopbackUpdate(active: true, snippet: trimmed)
    }

    private func sendLoopbackUpdate(active: Bool, snippet: String) {
        var components = URLComponents(string: "http://127.0.0.1:\(localBridgePort)/broadcast")
        components?.queryItems = [
            URLQueryItem(name: "active", value: active ? "1" : "0"),
            URLQueryItem(name: "text", value: snippet)
        ]
        guard let url = components?.url else { return }
        var req = URLRequest(url: url)
        req.timeoutInterval = 2.0

        URLSession.shared.dataTask(with: req) { [weak self] data, _, _ in
            guard let self,
                  let data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let targetLang = json["lang"] as? String,
                  !targetLang.isEmpty else { return }
            if targetLang != self.currentLocaleIdentifier {
                self.currentLocaleIdentifier = targetLang
                DispatchQueue.main.async {
                    self.startRecognition(localeIdentifier: targetLang)
                }
            }
        }.resume()
    }
}
