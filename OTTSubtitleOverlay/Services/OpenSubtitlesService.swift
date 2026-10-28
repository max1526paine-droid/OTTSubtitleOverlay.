import Foundation
import zlib

struct OpenSubtitleSearchResult: Identifiable {
    let id: String
    let title: String
    let releaseName: String
    let language: String
    let downloadCount: Int
    let downloadUrl: String?
    let embeddedTrack: SubtitleTrack?
}

@MainActor
final class OpenSubtitlesService: ObservableObject {
    static let shared = OpenSubtitlesService()

    @Published var isSearching: Bool = false
    @Published var isDownloading: Bool = false
    @Published var searchResults: [OpenSubtitleSearchResult] = []
    @Published var statusMessage: String = ""
    @Published var errorMessage: String?

    init() {
        self.searchResults = Self.builtInCatalogResults()
    }

    // MARK: - Keyless Web Subtitle Scourer (Free & Open REST API)

    struct DownloadedSRT {
        let title: String
        let languageCode: String
        let cues: [SubtitleCue]
    }

    /// Searches public subtitle mirrors on the web for any movie or TV series title (e.g. Squid Game, Shōgun, Demon Slayer).
    func searchSubtitles(query: String, season: String = "", episode: String = "") async {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            searchResults = Self.builtInCatalogResults()
            return
        }

        isSearching = true
        errorMessage = nil
        statusMessage = "Scouring the web for \"\(trimmed)\"..."
        defer { isSearching = false }

        let remoteMatches = await fetchRemoteSearchResults(query: trimmed, season: season, episode: episode)
        if !remoteMatches.isEmpty {
            self.searchResults = remoteMatches
            self.statusMessage = "Found \(remoteMatches.count) subtitle releases for \"\(trimmed)\"."
        } else {
            // Local matching fallback
            let local = Self.builtInCatalogResults().filter {
                $0.title.localizedCaseInsensitiveContains(trimmed) ||
                $0.releaseName.localizedCaseInsensitiveContains(trimmed)
            }
            self.searchResults = local.isEmpty ? Self.builtInCatalogResults() : local
            self.statusMessage = "No online matches. Showing built-in templates."
        }
    }

    private func fetchRemoteSearchResults(query: String, season: String, episode: String) async -> [OpenSubtitleSearchResult] {
        let cleanQuery = query.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? query
        var path = "sublanguageid-eng"
        if let s = Int(season), let e = Int(episode) {
            path += "/season-\(s)/episode-\(e)"
        }
        path += "/query-\(cleanQuery)"

        guard let url = URL(string: "https://rest.opensubtitles.org/search/\(path)") else { return [] }
        var request = URLRequest(url: url)
        request.timeoutInterval = 12
        request.setValue("TemporaryUserAgent", forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode),
                  let jsonArray = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
                return []
            }

            var results: [OpenSubtitleSearchResult] = []
            for item in jsonArray {
                let id = (item["IDSubtitleFile"] as? String) ?? UUID().uuidString
                let movieName = (item["MovieName"] as? String) ?? query
                let movieYear = (item["MovieYear"] as? String) ?? ""
                let release = (item["MovieReleaseName"] as? String) ?? movieName
                let dlLink = (item["SubDownloadLink"] as? String) ?? ""
                let lang = (item["LanguageName"] as? String) ?? "English"
                let dlCount = Int((item["SubDownloadsCnt"] as? String) ?? "0") ?? 0

                let displayTitle = movieYear.isEmpty ? movieName : "\(movieName) (\(movieYear))"
                results.append(
                    OpenSubtitleSearchResult(
                        id: id,
                        title: displayTitle,
                        releaseName: release,
                        language: lang,
                        downloadCount: dlCount,
                        downloadUrl: dlLink,
                        embeddedTrack: nil
                    )
                )
            }
            return results
        } catch {
            return []
        }
    }

    /// Downloads and parses the real .srt file from a search result item.
    func downloadSRT(from result: OpenSubtitleSearchResult) async -> DownloadedSRT? {
        guard let dlUrlString = result.downloadUrl,
              let url = URL(string: dlUrlString) else {
            return nil
        }

        isDownloading = true
        statusMessage = "Downloading subtitles for \(result.title)..."
        defer { isDownloading = false }

        var request = URLRequest(url: url)
        request.timeoutInterval = 15
        request.setValue("TemporaryUserAgent", forHTTPHeaderField: "User-Agent")

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
                statusMessage = "Download failed."
                return nil
            }

            // Decompress Gzip if needed
            let srtData = data.gunzipped() ?? data
            guard let srtText = String(data: srtData, encoding: .utf8) ??
                               String(data: srtData, encoding: .isoLatin1) else {
                statusMessage = "Could not decode subtitle text."
                return nil
            }

            let cues = SRTParser.parse(content: srtText)
            guard !cues.isEmpty else {
                statusMessage = "No dialogue cues found in file."
                return nil
            }

            statusMessage = "Loaded \(cues.count) dialogue lines for \"\(result.title)\"!"
            return DownloadedSRT(title: result.title, languageCode: "en", cues: cues)
        } catch {
            statusMessage = "Download error: \(error.localizedDescription)"
            return nil
        }
    }

    /// Automatically scours the web for the given show, downloads the top English SRT release, and returns the track.
    func autoScourAndDownload(query: String, season: String = "", episode: String = "") async -> DownloadedSRT? {
        await searchSubtitles(query: query, season: season, episode: episode)
        for candidate in searchResults {
            if candidate.downloadUrl != nil {
                if let downloaded = await downloadSRT(from: candidate) {
                    return downloaded
                }
            }
        }
        return nil
    }

    // MARK: - Built-in Catalog Fallbacks

    static func builtInCatalogResults() -> [OpenSubtitleSearchResult] {
        let tracks = builtInTracks()
        return tracks.map { track in
            OpenSubtitleSearchResult(
                id: track.id.uuidString,
                title: track.title,
                releaseName: "\(track.sourceLanguage.flagEmoji) \(track.sourceLanguage.displayName) → English Dual Subtitles",
                language: "\(track.sourceLanguage.shortCode) → EN",
                downloadCount: 14200,
                downloadUrl: nil,
                embeddedTrack: track
            )
        }
    }

    static func builtInTracks() -> [SubtitleTrack] {
        [
            SubtitleTrack(
                id: UUID(),
                title: "Squid Game (오징어 게임) [KO → EN]",
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
                title: "Demon Slayer (鬼滅の刃) [JA → EN]",
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
                title: "Money Heist (La Casa de Papel) [ES → EN]",
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

// MARK: - Native Gzip Decompression (zlib)

extension Data {
    func gunzipped() -> Data? {
        guard self.count > 10 else { return nil }
        var stream = z_stream()
        var status = inflateInit2_(&stream, MAX_WBITS + 32, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size))
        guard status == Z_OK else { return nil }
        var decompressed = Data(capacity: self.count * 4)

        self.withUnsafeBytes { rawBuffer in
            guard let base = rawBuffer.bindMemory(to: Bytef.self).baseAddress else { return }
            stream.next_in = UnsafeMutablePointer<Bytef>(mutating: base)
            stream.avail_in = uInt(self.count)

            let bufferSize = 65536
            let buffer = UnsafeMutablePointer<Bytef>.allocate(capacity: bufferSize)
            defer { buffer.deallocate() }

            repeat {
                stream.next_out = buffer
                stream.avail_out = uInt(bufferSize)
                status = inflate(&stream, Z_NO_FLUSH)
                let bytesRead = bufferSize - Int(stream.avail_out)
                if bytesRead > 0 {
                    decompressed.append(buffer, count: bytesRead)
                }
            } while status == Z_OK
            inflateEnd(&stream)
        }
        return (status == Z_STREAM_END || !decompressed.isEmpty) ? decompressed : nil
    }
}
