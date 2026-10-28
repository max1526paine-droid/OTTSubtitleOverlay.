import Foundation

// MARK: - Translation Result & Error

struct TranslationResult {
    let translatedText: String
    let provider: AIProvider
    let didFailover: Bool
    let failoverReason: String?
}

enum TranslationProviderError: LocalizedError {
    case missingAPIKey(AIProvider)
    case tokenOrQuotaExhausted(AIProvider, Int)
    case invalidResponse(AIProvider)
    case networkError(AIProvider, Error)

    var errorDescription: String? {
        switch self {
        case .missingAPIKey(let provider):
            return "\(provider.shortBadge) API key not configured."
        case .tokenOrQuotaExhausted(let provider, let code):
            return "\(provider.shortBadge) token/quota exhausted (HTTP \(code)). Switched to backup provider."
        case .invalidResponse(let provider):
            return "\(provider.shortBadge) returned an unexpected response."
        case .networkError(let provider, let err):
            return "\(provider.shortBadge) network error: \(err.localizedDescription)"
        }
    }
}

// MARK: - Multi-Provider AI Translation Service (ChatGPT -> Gemini 3.8 -> Free Fallback)

@MainActor
final class TranslationService: ObservableObject {
    static let shared = TranslationService()

    @Published var openAIKey: String {
        didSet {
            UserDefaults.standard.set(openAIKey, forKey: AppGroupConfig.openaiKeyStorage)
            UserDefaults(suiteName: AppGroupConfig.suiteName)?.set(openAIKey, forKey: AppGroupConfig.openaiKeyStorage)
        }
    }

    @Published var geminiKey: String {
        didSet {
            UserDefaults.standard.set(geminiKey, forKey: AppGroupConfig.geminiKeyStorage)
            UserDefaults(suiteName: AppGroupConfig.suiteName)?.set(geminiKey, forKey: AppGroupConfig.geminiKeyStorage)
        }
    }

    @Published var failoverOrder: TranslationFailoverOrder {
        didSet {
            UserDefaults.standard.set(failoverOrder.rawValue, forKey: AppGroupConfig.failoverOrderStorage)
        }
    }

    @Published var activeProvider: AIProvider = .chatGPT
    @Published var lastFailoverNotice: String?
    @Published var chatGPTQuotaExhausted: Bool = false
    @Published var gemini38QuotaExhausted: Bool = false

    private var cache: [String: String] = [:]
    private let session: URLSession

    init() {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 8.0
        config.waitsForConnectivity = false
        self.session = URLSession(configuration: config)

        self.openAIKey = UserDefaults.standard.string(forKey: AppGroupConfig.openaiKeyStorage) ?? ""
        self.geminiKey = UserDefaults.standard.string(forKey: AppGroupConfig.geminiKeyStorage) ?? ""

        if let savedOrder = UserDefaults.standard.string(forKey: AppGroupConfig.failoverOrderStorage),
           let order = TranslationFailoverOrder(rawValue: savedOrder) {
            self.failoverOrder = order
        } else {
            // Default per user requirement: ChatGPT first, then Gemini 3.8, then Free Fallback
            self.failoverOrder = .chatGPTThenGemini38
        }
    }

    func resetQuotaFlags() {
        chatGPTQuotaExhausted = false
        gemini38QuotaExhausted = false
        lastFailoverNotice = nil
    }

    /// Translates source dialogue (Korean, Japanese, etc.) into natural, concise English OTT subtitles.
    /// Automatically fails over: ChatGPT -> Gemini 3.8 (`gemini-3.8-flash`) -> Free Keyless API when tokens/quota end.
    func translateToEnglish(
        text: String,
        sourceLanguage: SourceLanguage,
        recentContext: String? = nil
    ) async -> TranslationResult {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return TranslationResult(translatedText: "", provider: activeProvider, didFailover: false, failoverReason: nil)
        }

        let cacheKey = "\(sourceLanguage.iso639Code):\(trimmed)"
        if let cached = cache[cacheKey] {
            return TranslationResult(translatedText: cached, provider: activeProvider, didFailover: false, failoverReason: nil)
        }

        let providers = orderedProviders()
        var failoverReasons: [String] = []

        for (index, provider) in providers.enumerated() {
            do {
                let translated: String
                switch provider {
                case .chatGPT:
                    if chatGPTQuotaExhausted {
                        throw TranslationProviderError.tokenOrQuotaExhausted(.chatGPT, 429)
                    }
                    translated = try await translateWithChatGPT(
                        text: trimmed,
                        sourceLanguage: sourceLanguage,
                        context: recentContext
                    )
                case .gemini38, .geminiLive:
                    if gemini38QuotaExhausted {
                        throw TranslationProviderError.tokenOrQuotaExhausted(.gemini38, 429)
                    }
                    translated = try await translateWithGemini38InteractionsAPI(
                        text: trimmed,
                        sourceLanguage: sourceLanguage,
                        context: recentContext
                    )
                case .freeFallback:
                    translated = try await translateWithFreeKeylessAPI(
                        text: trimmed,
                        sourceLanguage: sourceLanguage
                    )
                }

                let cleaned = Self.cleanSubtitleOutput(translated)
                if !cleaned.isEmpty {
                    cache[cacheKey] = cleaned
                    activeProvider = provider
                    let didFailover = index > 0
                    let reason = failoverReasons.isEmpty ? nil : failoverReasons.joined(separator: " → ")
                    if let reason {
                        lastFailoverNotice = reason
                    }
                    return TranslationResult(
                        translatedText: cleaned,
                        provider: provider,
                        didFailover: didFailover,
                        failoverReason: reason
                    )
                }
            } catch {
                let reason = error.localizedDescription
                failoverReasons.append(reason)
                continue
            }
        }

        // Ultimate offline fallback if no network is reachable
        return TranslationResult(
            translatedText: "[Offline] \(trimmed)",
            provider: .freeFallback,
            didFailover: true,
            failoverReason: failoverReasons.joined(separator: " | ")
        )
    }

    private func orderedProviders() -> [AIProvider] {
        switch failoverOrder {
        case .chatGPTThenGemini38, .geminiLiveDirectAudio:
            return [.chatGPT, .gemini38, .freeFallback]
        case .gemini38ThenChatGPT:
            return [.gemini38, .chatGPT, .freeFallback]
        }
    }

    // MARK: - 1. OpenAI ChatGPT (gpt-4o-mini) Implementation

    private func translateWithChatGPT(
        text: String,
        sourceLanguage: SourceLanguage,
        context: String?
    ) async throws -> String {
        let key = openAIKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else {
            throw TranslationProviderError.missingAPIKey(.chatGPT)
        }

        let url = URL(string: "https://api.openai.com/v1/chat/completions")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")

        var systemPrompt = """
        You are a professional OTT subtitle translator for Netflix and Amazon Prime Video.
        Translate \(sourceLanguage.displayName) dialogue into natural, idiomatic English subtitles.
        Output ONLY the English subtitle text (1-2 short lines max, no quotes, no explanations).
        Preserve emotional tone, Korean/Japanese honorific nuances, and dramatic pacing.
        """
        if let context, !context.isEmpty {
            systemPrompt += "\nPrevious line for context: \(context)"
        }

        let payload: [String: Any] = [
            "model": "gpt-4o-mini",
            "temperature": 0.2,
            "max_tokens": 120,
            "messages": [
                ["role": "system", "content": systemPrompt],
                ["role": "user", "content": text]
            ]
        ]

        request.httpBody = try JSONSerialization.data(withJSONObject: payload)

        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw TranslationProviderError.networkError(.chatGPT, error)
        }

        guard let http = response as? HTTPURLResponse else {
            throw TranslationProviderError.invalidResponse(.chatGPT)
        }

        if http.statusCode == 429 || http.statusCode == 401 || http.statusCode == 402 || http.statusCode == 403 {
            // Mark ChatGPT quota/token exhausted so subsequent lines immediately use Gemini 3.8!
            chatGPTQuotaExhausted = true
            throw TranslationProviderError.tokenOrQuotaExhausted(.chatGPT, http.statusCode)
        }

        guard (200...299).contains(http.statusCode),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = json["choices"] as? [[String: Any]],
              let message = choices.first?["message"] as? [String: Any],
              let content = message["content"] as? String else {
            throw TranslationProviderError.invalidResponse(.chatGPT)
        }

        return content
    }

    // MARK: - 2. Gemini 3.8 (`gemini-3.8-flash`) Official Interactions API Implementation

    private func translateWithGemini38InteractionsAPI(
        text: String,
        sourceLanguage: SourceLanguage,
        context: String?
    ) async throws -> String {
        let key = geminiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else {
            throw TranslationProviderError.missingAPIKey(.gemini38)
        }

        // Official Gemini 3.8 Interactions API endpoint (/v1beta2/interactions)
        let url = URL(string: "https://generativelanguage.googleapis.com/v1beta2/interactions")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(key, forHTTPHeaderField: "x-goog-api-key")

        var systemInstruction = """
        You are an expert OTT subtitle translator for Netflix and Amazon Prime Video.
        Translate \(sourceLanguage.displayName) dialogue into natural, concise English subtitles.
        Return ONLY the translated English subtitle line with no commentary or quotes.
        """
        if let context, !context.isEmpty {
            systemInstruction += " Previous dialogue context: \(context)"
        }

        let payload: [String: Any] = [
            "model": "gemini-3.8-flash",
            "system_instruction": systemInstruction,
            "input": text,
            "store": false
        ]

        request.httpBody = try JSONSerialization.data(withJSONObject: payload)

        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw TranslationProviderError.networkError(.gemini38, error)
        }

        guard let http = response as? HTTPURLResponse else {
            throw TranslationProviderError.invalidResponse(.gemini38)
        }

        if http.statusCode == 429 || http.statusCode == 401 || http.statusCode == 403 {
            gemini38QuotaExhausted = true
            throw TranslationProviderError.tokenOrQuotaExhausted(.gemini38, http.statusCode)
        }

        guard (200...299).contains(http.statusCode),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw TranslationProviderError.invalidResponse(.gemini38)
        }

        // Parse Interactions API response (`output_text` or `steps` array with `model_output`)
        if let outputText = json["output_text"] as? String, !outputText.isEmpty {
            return outputText
        }

        if let steps = json["steps"] as? [[String: Any]] {
            var collected: [String] = []
            for step in steps where (step["type"] as? String) == "model_output" {
                if let contentArray = step["content"] as? [[String: Any]] {
                    for part in contentArray where (part["type"] as? String) == "text" {
                        if let partText = part["text"] as? String {
                            collected.append(partText)
                        }
                    }
                }
            }
            if !collected.isEmpty {
                return collected.joined(separator: " ")
            }
        }

        throw TranslationProviderError.invalidResponse(.gemini38)
    }

    // MARK: - 3. Free Keyless Translation API (MyMemory REST API)

    private func translateWithFreeKeylessAPI(
        text: String,
        sourceLanguage: SourceLanguage
    ) async throws -> String {
        var components = URLComponents(string: "https://api.mymemory.translated.net/get")!
        components.queryItems = [
            URLQueryItem(name: "q", value: text),
            URLQueryItem(name: "langpair", value: "\(sourceLanguage.iso639Code)|en")
        ]

        guard let url = components.url else {
            throw TranslationProviderError.invalidResponse(.freeFallback)
        }

        let (data, response) = try await session.data(from: url)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let responseData = json["responseData"] as? [String: Any],
              let translatedText = responseData["translatedText"] as? String else {
            throw TranslationProviderError.invalidResponse(.freeFallback)
        }

        return translatedText
    }

    private static func cleanSubtitleOutput(_ raw: String) -> String {
        raw.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "^\"|\"$", with: "", options: .regularExpression)
    }
}
