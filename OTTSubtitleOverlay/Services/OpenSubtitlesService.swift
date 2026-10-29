import Foundation
import zlib

struct OpenSubtitleSearchResult: Identifiable {
    let id: String
    let title: String
    let releaseName: String
    let language: String
    let downloadCount: Int
    let downloadUrl: String?
    let season: Int?
    let episode: Int?
    let embeddedTrack: SubtitleTrack?
}

@MainActor
final class OpenSubtitlesService: ObservableObject {
    static let shared = OpenSubtitlesService()

    @Published var apiKey: String = ""
    @Published var isSearching: Bool = false
    @Published var isDownloading: Bool = false
    @Published var searchResults: [OpenSubtitleSearchResult] = []
    @Published var statusMessage: String = ""
    @Published var errorMessage: String?

    init() {
        self.searchResults = []
    }

    struct DownloadedSRT {
        let title: String
        let languageCode: String
        let cues: [SubtitleCue]
    }

    /// Parses inline episode/season markers like "Teach you a lesson ep 6" or "s01e06"
    static func extractQuerySeasonEpisode(rawQuery: String, rawSeason: String, rawEpisode: String) -> (cleanQuery: String, season: Int?, episode: Int?) {
        var q = rawQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        var s = Int(rawSeason.trimmingCharacters(in: .whitespacesAndNewlines))
        var e = Int(rawEpisode.trimmingCharacters(in: .whitespacesAndNewlines))

        // Match S01E06 or 1x06
        if let regex = try? NSRegularExpression(pattern: "(?i)\\b(?:s(\\d{1,2})\\s*e(\\d{1,3})|(\\d{1,2})x(\\d{1,3}))\\b"),
           let match = regex.firstMatch(in: q, range: NSRange(q.startIndex..., in: q)) {
            if let r1 = Range(match.range(at: 1), in: q), let r2 = Range(match.range(at: 2), in: q) {
                s = s ?? Int(q[r1])
                e = e ?? Int(q[r2])
            } else if let r3 = Range(match.range(at: 3), in: q), let r4 = Range(match.range(at: 4), in: q) {
                s = s ?? Int(q[r3])
                e = e ?? Int(q[r4])
            }
            if let fullRange = Range(match.range, in: q) {
                q.removeSubrange(fullRange)
            }
        }

        // Match "ep 6", "ep. 6", "episode 6", "e6"
        if let regex = try? NSRegularExpression(pattern: "(?i)\\b(?:episode|ep\\.?|e)\\s*(\\d{1,3})\\b"),
           let match = regex.firstMatch(in: q, range: NSRange(q.startIndex..., in: q)),
           let epRange = Range(match.range(at: 1), in: q) {
            e = e ?? Int(q[epRange])
            if let fullRange = Range(match.range, in: q) {
                q.removeSubrange(fullRange)
            }
        }

        q = q.trimmingCharacters(in: .whitespacesAndNewlines)
        return (q.isEmpty ? rawQuery.trimmingCharacters(in: .whitespacesAndNewlines) : q, s, e)
    }

    /// Searches public subtitle mirrors on the web for any movie or TV series title.
    func searchSubtitles(query: String, season: String = "", episode: String = "") async {
        let parsed = Self.extractQuerySeasonEpisode(rawQuery: query, rawSeason: season, rawEpisode: episode)
        guard !parsed.cleanQuery.isEmpty else {
            searchResults = []
            statusMessage = ""
            return
        }

        isSearching = true
        errorMessage = nil
        if let ep = parsed.episode {
            statusMessage = "Searching English subtitles for \"\(parsed.cleanQuery)\" Episode \(ep)..."
        } else {
            statusMessage = "Searching English subtitles for \"\(parsed.cleanQuery)\"..."
        }
        defer { isSearching = false }

        var remoteMatches = await fetchRemoteSearchResults(
            query: parsed.cleanQuery,
            season: parsed.season,
            episode: parsed.episode
        )

        // Fallback: if filtering by season/episode returned nothing, fetch all episodes for the show and sort Episode match to top
        if remoteMatches.isEmpty && (parsed.season != nil || parsed.episode != nil) {
            remoteMatches = await fetchRemoteSearchResults(
                query: parsed.cleanQuery,
                season: nil,
                episode: nil
            )
            if let targetEp = parsed.episode {
                let exact = remoteMatches.filter { $0.episode == targetEp }
                if !exact.isEmpty {
                    remoteMatches = exact
                }
            }
        }

        if !remoteMatches.isEmpty {
            self.searchResults = remoteMatches
            if let ep = parsed.episode {
                self.statusMessage = "Found \(remoteMatches.count) English subtitle release(s) for Episode \(ep). Tap any release or watch it play automatically."
            } else {
                self.statusMessage = "Found \(remoteMatches.count) English subtitle releases. Tap your episode below to start."
            }
        } else {
            self.searchResults = []
            self.statusMessage = "No subtitles found for \"\(parsed.cleanQuery)\". Please check the spelling."
        }
    }

    private func fetchRemoteSearchResults(query: String, season: Int?, episode: Int?) async -> [OpenSubtitleSearchResult] {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        let cleanQuery = query.lowercased().addingPercentEncoding(withAllowedCharacters: allowed) ?? query

        // IMPORTANT: rest.opensubtitles.org requires path segments after /search/ to be sorted alphabetically
        // to avoid a 302 redirect.
        var segments: [String] = [
            "query-\(cleanQuery)",
            "sublanguageid-eng"
        ]
        if let s = season, s > 0 {
            segments.append("season-\(s)")
        }
        if let e = episode, e > 0 {
            segments.append("episode-\(e)")
        }
        segments.sort()
        let path = segments.joined(separator: "/")

        guard let url = URL(string: "https://rest.opensubtitles.org/search/\(path)") else { return [] }
        var request = URLRequest(url: url)
        request.timeoutInterval = 15
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
                let rawMovieName = (item["MovieName"] as? String) ?? query
                let movieName = rawMovieName.replacingOccurrences(of: "\"", with: "")
                let release = (item["MovieReleaseName"] as? String) ?? movieName
                var dlLink = (item["SubDownloadLink"] as? String) ?? ""
                if dlLink.hasPrefix("http://") {
                    dlLink = dlLink.replacingOccurrences(of: "http://", with: "https://")
                }
                let lang = (item["LanguageName"] as? String) ?? "English"
                let dlCount = Int((item["SubDownloadsCnt"] as? String) ?? "0") ?? 0
                let sNum = Int((item["SeriesSeason"] as? String) ?? "")
                let eNum = Int((item["SeriesEpisode"] as? String) ?? "")

                let displayTitle: String
                if let s = sNum, let e = eNum, (s > 0 || e > 0) {
                    let epBadge = String(format: "S%02dE%02d (Ep %d)", max(1, s), e, e)
                    displayTitle = "\(epBadge) • \(movieName)"
                } else if let e = eNum, e > 0 {
                    displayTitle = "Episode \(e) • \(movieName)"
                } else {
                    displayTitle = movieName
                }

                results.append(
                    OpenSubtitleSearchResult(
                        id: id,
                        title: displayTitle,
                        releaseName: release,
                        language: lang,
                        downloadCount: dlCount,
                        downloadUrl: dlLink,
                        season: sNum,
                        episode: eNum,
                        embeddedTrack: nil
                    )
                )
            }

            // Sort by Season -> Episode -> Download Count descending
            results.sort { a, b in
                if let targetEp = episode {
                    let aMatch = (a.episode == targetEp)
                    let bMatch = (b.episode == targetEp)
                    if aMatch != bMatch { return aMatch }
                }
                let sA = a.season ?? 999
                let sB = b.season ?? 999
                if sA != sB { return sA < sB }
                let eA = a.episode ?? 999
                let eB = b.episode ?? 999
                if eA != eB { return eA < eB }
                return a.downloadCount > b.downloadCount
            }

            return results
        } catch {
            return []
        }
    }

    /// Downloads and parses the real .srt file from a search result item.
    func downloadSRT(from result: OpenSubtitleSearchResult) async -> DownloadedSRT? {
        guard var dlUrlString = result.downloadUrl else { return nil }
        if dlUrlString.hasPrefix("http://") {
            dlUrlString = dlUrlString.replacingOccurrences(of: "http://", with: "https://")
        }
        guard let url = URL(string: dlUrlString) else { return nil }

        isDownloading = true
        statusMessage = "Downloading \(result.title)..."
        defer { isDownloading = false }

        var request = URLRequest(url: url)
        request.timeoutInterval = 15
        request.setValue("TemporaryUserAgent", forHTTPHeaderField: "User-Agent")

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
                statusMessage = "Download failed (HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0))."
                return nil
            }

            // Decompress Gzip if needed
            let srtData = data.gunzipped() ?? data
            let srtText = String(data: srtData, encoding: .utf8)
                ?? String(decoding: srtData, as: UTF8.self)

            let cues = SRTParser.parse(content: srtText)
            guard !cues.isEmpty else {
                statusMessage = "No dialogue cues found in file."
                return nil
            }

            statusMessage = "Playing \(cues.count) real English lines for \(result.title)!"
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
