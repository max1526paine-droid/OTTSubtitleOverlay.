import Foundation

struct OpenSubtitleSearchResult: Identifiable {
    let id: String
    let title: String
    let releaseName: String
    let language: String
    let downloadCount: Int
    let fileId: Int?
    let embeddedTrack: SubtitleTrack?
}

@MainActor
final class OpenSubtitlesService: ObservableObject {
    static let shared = OpenSubtitlesService()

    @Published var apiKey: String {
        didSet {
            UserDefaults.standard.set(apiKey, forKey: "opensubtitles_api_key")
        }
    }

    @Published var isSearching: Bool = false
    @Published var searchResults: [OpenSubtitleSearchResult] = []
    @Published var errorMessage: String?

    init() {
        self.apiKey = UserDefaults.standard.string(forKey: "opensubtitles_api_key") ?? ""
        self.searchResults = Self.builtInCatalogResults()
    }

    func searchSubtitles(query: String, season: String = "", episode: String = "") async {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            searchResults = Self.builtInCatalogResults()
            return
        }

        isSearching = true
        errorMessage = nil
        defer { isSearching = false }

        // Always match built-in demo catalog first for instant offline/zero-key availability
        let localMatches = Self.builtInCatalogResults().filter {
            $0.title.localizedCaseInsensitiveContains(trimmed) ||
            $0.releaseName.localizedCaseInsensitiveContains(trimmed)
        }

        let cleanKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanKey.isEmpty else {
            searchResults = localMatches.isEmpty ? Self.builtInCatalogResults() : localMatches
            return
        }

        var components = URLComponents(string: "https://api.opensubtitles.com/api/v1/subtitles")!
        var items: [URLQueryItem] = [
            URLQueryItem(name: "query", value: trimmed),
            URLQueryItem(name: "languages", value: "en")
        ]
        if let s = Int(season) {
            items.append(URLQueryItem(name: "season_number", value: String(s)))
        }
        if let e = Int(episode) {
            items.append(URLQueryItem(name: "episode_number", value: String(e)))
        }
        components.queryItems = items

        guard let url = components.url else { return }

        var request = URLRequest(url: url)
        request.setValue(cleanKey, forHTTPHeaderField: "Api-Key")
        request.setValue("OTTSubtitleOverlay v1.0", forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode),
                  let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let dataArray = root["data"] as? [[String: Any]] else {
                searchResults = localMatches
                errorMessage = "OpenSubtitles API returned non-200 status. Showing built-in tracks."
                return
            }

            var parsed: [OpenSubtitleSearchResult] = localMatches
            for item in dataArray {
                let id = (item["id"] as? String) ?? UUID().uuidString
                let attrs = (item["attributes"] as? [String: Any]) ?? [:]
                let release = (attrs["release"] as? String) ?? trimmed
                let lang = (attrs["language"] as? String) ?? "en"
                let downloads = (attrs["download_count"] as? Int) ?? 0
                let feature = (attrs["feature_details"] as? [String: Any]) ?? [:]
                let title = (feature["movie_name"] as? String) ?? trimmed
                let files = (attrs["files"] as? [[String: Any]]) ?? []
                let fileId = files.first?["file_id"] as? Int

                parsed.append(
                    OpenSubtitleSearchResult(
                        id: id,
                        title: title,
                        releaseName: release,
                        language: lang.uppercased(),
                        downloadCount: downloads,
                        fileId: fileId,
                        embeddedTrack: nil
                    )
                )
            }
            searchResults = parsed
        } catch {
            errorMessage = "Network error: \(error.localizedDescription)"
            searchResults = localMatches
        }
    }

    // MARK: - Built-in Multi-Language Demo Subtitle Tracks (Korean, Japanese, Spanish -> English)

    static func builtInCatalogResults() -> [OpenSubtitleSearchResult] {
        let tracks = builtInTracks()
        return tracks.map { track in
            OpenSubtitleSearchResult(
                id: track.id.uuidString,
                title: track.title,
                releaseName: "\(track.sourceLanguage.flagEmoji) \(track.sourceLanguage.displayName) → English Dual Subtitles",
                language: "\(track.sourceLanguage.shortCode) → EN",
                downloadCount: 14200,
                fileId: nil,
                embeddedTrack: track
            )
        }
    }

    static func builtInTracks() -> [SubtitleTrack] {
        [
            SubtitleTrack(
                id: UUID(),
                title: "K-Drama Sample: Squid Game / Seoul Noir (KO → EN)",
                sourceLanguage: .korean,
                cues: [
                    SubtitleCue(index: 1, startTime: 0, endTime: 4, originalText: "기훈 씨, 이제 선택할 시간입니다.", translatedText: "Gi-hun, it is time to make your choice now."),
                    SubtitleCue(index: 2, startTime: 4, endTime: 8, originalText: "여기서 포기하면 모든 게 끝나요.", translatedText: "If you give up here, everything ends."),
                    SubtitleCue(index: 3, startTime: 8, endTime: 13, originalText: "우린 반드시 살아서 이 섬을 빠져나갈 거야.", translatedText: "We are definitely getting off this island alive."),
                    SubtitleCue(index: 4, startTime: 13, endTime: 18, originalText: "아무도 믿지 마세요. 게임은 이미 시작됐으니까요.", translatedText: "Don't trust anyone. Because the game has already begun."),
                    SubtitleCue(index: 5, startTime: 18, endTime: 24, originalText: "마지막 라운드가 곧 시작됩니다. 참가자분들은 준비해 주십시오.", translatedText: "The final round will begin shortly. Players, please get ready."),
                    SubtitleCue(index: 6, startTime: 24, endTime: 30, originalText: "약속했잖아, 끝까지 함께 가기로!", translatedText: "You promised me that we would go all the way to the end together!")
                ]
            ),
            SubtitleTrack(
                id: UUID(),
                title: "Anime Sample: Demon Blade / Tokyo Arc (JA → EN)",
                sourceLanguage: .japanese,
                cues: [
                    SubtitleCue(index: 1, startTime: 0, endTime: 4, originalText: "諦めるな！まだ戦いは終わっていない！", translatedText: "Don't give up! The battle isn't over yet!"),
                    SubtitleCue(index: 2, startTime: 4, endTime: 9, originalText: "この一撃にすべての力を込める。", translatedText: "I will pour all of my strength into this single strike."),
                    SubtitleCue(index: 3, startTime: 9, endTime: 14, originalText: "仲間を守るためなら、俺は何度でも立ち上がる。", translatedText: "To protect my friends, I will stand up as many times as it takes."),
                    SubtitleCue(index: 4, startTime: 14, endTime: 19, originalText: "気をつけろ、奴の気配が背後から迫っている！", translatedText: "Watch out, his presence is closing in right behind you!"),
                    SubtitleCue(index: 5, startTime: 19, endTime: 25, originalText: "夜明けが来るまで、ここを絶対に死守するんだ！", translatedText: "Until dawn breaks, we must hold this line no matter what!")
                ]
            ),
            SubtitleTrack(
                id: UUID(),
                title: "Spanish Thriller: La Casa Heist (ES → EN)",
                sourceLanguage: .spanish,
                cues: [
                    SubtitleCue(index: 1, startTime: 0, endTime: 4, originalText: "Profesor, la policía ha rodeado todo el edificio.", translatedText: "Professor, the police have surrounded the entire building."),
                    SubtitleCue(index: 2, startTime: 4, endTime: 9, originalText: "Mantengan la calma. Todo esto estaba previsto en el plan.", translatedText: "Stay calm. All of this was accounted for in the plan."),
                    SubtitleCue(index: 3, startTime: 9, endTime: 15, originalText: "Nadie dispara ni una sola bala sin mi orden directa.", translatedText: "Nobody fires a single bullet without my direct order.")
                ]
            )
        ]
    }
}
