import Foundation

/// Connects directly to the Gemini Live WebSocket API (`gemini-3.5-live-translate-preview` / `gemini-3.8-live`)
/// for ultra-low-latency streaming audio-to-English subtitle translation.
final class GeminiLiveWebSocketClient: NSObject, URLSessionWebSocketDelegate {
    private var webSocketTask: URLSessionWebSocketTask?
    private var urlSession: URLSession?
    private(set) var isConnected: Bool = false

    var onTranscriptReceived: ((String?, String) -> Void)?
    var onSessionDisconnected: ((Error?) -> Void)?

    private var currentOriginalBuffer: String = ""
    private var currentTranslatedBuffer: String = ""

    func connect(apiKey: String, targetLanguageCode: String = "en", useLive38Agent: Bool = false) {
        disconnect()

        let trimmedKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedKey.isEmpty,
              let url = URL(string: "wss://generativelanguage.googleapis.com/ws/google.ai.generativelanguage.v1beta.GenerativeService.BidiGenerateContent?key=\(trimmedKey)") else {
            return
        }

        let session = URLSession(configuration: .default, delegate: self, delegateQueue: OperationQueue())
        self.urlSession = session
        let task = session.webSocketTask(with: url)
        self.webSocketTask = task
        task.resume()

        sendSetupMessage(targetLanguageCode: targetLanguageCode, useLive38Agent: useLive38Agent)
        receiveNextMessage()
    }

    private func sendSetupMessage(targetLanguageCode: String, useLive38Agent: Bool) {
        let setupPayload: [String: Any]
        if useLive38Agent {
            // Gemini 3.8 Live (`models/gemini-3.8-live`) setup with input & output transcription
            setupPayload = [
                "setup": [
                    "model": "models/gemini-3.8-live",
                    "generationConfig": [
                        "responseModalities": ["AUDIO"]
                    ],
                    "inputAudioTranscription": [:],
                    "outputAudioTranscription": [:],
                    "systemInstruction": [
                        "parts": [
                            ["text": "You are a real-time OTT subtitle interpreter. Translate all incoming foreign speech into concise, natural English dialogue immediately."]
                        ]
                    ]
                ]
            ]
        } else {
            // Gemini Live Translate (`models/gemini-3.5-live-translate-preview`) continuous interpreter pipeline
            setupPayload = [
                "setup": [
                    "model": "models/gemini-3.5-live-translate-preview",
                    "generationConfig": [
                        "responseModalities": ["AUDIO"],
                        "inputAudioTranscription": [:],
                        "outputAudioTranscription": [:],
                        "translationConfig": [
                            "targetLanguageCode": targetLanguageCode,
                            "echoTargetLanguage": true
                        ]
                    ]
                ]
            ]
        }

        guard let data = try? JSONSerialization.data(withJSONObject: setupPayload),
              let jsonString = String(data: data, encoding: .utf8) else {
            return
        }

        webSocketTask?.send(.string(jsonString)) { [weak self] error in
            if let error {
                self?.onSessionDisconnected?(error)
            } else {
                self?.isConnected = true
            }
        }
    }

    /// Sends raw 16kHz 16-bit mono little-endian PCM audio chunk (`audio/pcm;rate=16000`) per Gemini Live API spec.
    func sendPCM16kAudioChunk(_ pcmData: Data) {
        guard isConnected, let webSocketTask else { return }

        let message: [String: Any] = [
            "realtimeInput": [
                "audio": [
                    "data": pcmData.base64EncodedString(),
                    "mimeType": "audio/pcm;rate=16000"
                ]
            ]
        ]

        guard let jsonData = try? JSONSerialization.data(withJSONObject: message),
              let jsonString = String(data: jsonData, encoding: .utf8) else {
            return
        }

        webSocketTask.send(.string(jsonString)) { _ in }
    }

    func sendAudioStreamEnd() {
        guard isConnected, let webSocketTask else { return }
        let message: [String: Any] = [
            "realtimeInput": [
                "audioStreamEnd": true
            ]
        ]
        if let jsonData = try? JSONSerialization.data(withJSONObject: message),
           let jsonString = String(data: jsonData, encoding: .utf8) {
            webSocketTask.send(.string(jsonString)) { _ in }
        }
    }

    private func receiveNextMessage() {
        webSocketTask?.receive { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let message):
                switch message {
                case .string(let text):
                    self.handleServerJSON(text)
                case .data(let data):
                    if let text = String(data: data, encoding: .utf8) {
                        self.handleServerJSON(text)
                    }
                @unknown default:
                    break
                }
                self.receiveNextMessage()

            case .failure(let error):
                self.isConnected = false
                self.onSessionDisconnected?(error)
            }
        }
    }

    private func handleServerJSON(_ jsonString: String) {
        guard let data = jsonString.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let serverContent = root["serverContent"] as? [String: Any] else {
            return
        }

        // Process ALL parts in each server event per Gemini Live API best practices
        if let inputTrans = serverContent["inputTranscription"] as? [String: Any],
           let text = inputTrans["text"] as? String, !text.isEmpty {
            currentOriginalBuffer = text
        }

        if let outputTrans = serverContent["outputTranscription"] as? [String: Any],
           let text = outputTrans["text"] as? String, !text.isEmpty {
            currentTranslatedBuffer = text
            onTranscriptReceived?(currentOriginalBuffer.isEmpty ? nil : currentOriginalBuffer, currentTranslatedBuffer)
        }
    }

    func disconnect() {
        isConnected = false
        webSocketTask?.cancel(with: .goingAway, reason: nil)
        webSocketTask = nil
        urlSession?.invalidateAndCancel()
        urlSession = nil
    }
}
