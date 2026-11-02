import Foundation
import zlib

@MainActor
final class OpenSubtitlesService: ObservableObject {
    static let shared = OpenSubtitlesService()

    @Published var isSearching: Bool = false
    @Published var isDownloading: Bool = false
    @Published var searchResults: [SubtitleSearchResult] = []
    @Published var statusMessage: String = ""
    @Published var errorMessage: String?

    init() {
        self.searchResults = []
    }

    struct DownloadedSubtitle {
        let title: String
        let cues: [SubtitleCue]
    }

    /// Extracts season/episode from queries like "Show ep 6", "Show s01e06", "Show 1x06"
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

        // Match "ep 6", "ep. 6", "episode 6"
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

    /// Searches OpenSubtitles for English subtitles matching any movie or series.
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
            statusMessage = "Searching English subtitles for \"\(parsed.cleanQuery)\" Ep \(ep)..."
        } else {
            statusMessage = "Searching English subtitles for \"\(parsed.cleanQuery)\"..."
        }
        defer { isSearching = false }

        var remoteMatches = await fetchRemote(
            query: parsed.cleanQuery,
            season: parsed.season,
            episode: parsed.episode
        )

        // Fallback: If filtering by season/episode returned 0 results, search all episodes of the series
        if remoteMatches.isEmpty && (parsed.season != nil || parsed.episode != nil) {
            remoteMatches = await fetchRemote(
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
                self.statusMessage = "Found \(remoteMatches.count) English release(s) for Ep \(ep). Tap to play."
            } else {
                self.statusMessage = "Found \(remoteMatches.count) English subtitle releases. Tap your episode to play."
            }
        } else {
            self.searchResults = []
            self.statusMessage = "No subtitles found for \"\(parsed.cleanQuery)\". Check title spelling."
        }
    }

    private func fetchRemote(query: String, season: Int?, episode: Int?) async -> [SubtitleSearchResult] {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        let cleanQuery = query.lowercased().addingPercentEncoding(withAllowedCharacters: allowed) ?? query

        // Path segments must be alphabetical to avoid 302 redirects
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
        request.timeoutInterval = 12
        request.setValue("TemporaryUserAgent", forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode),
                  let jsonArray = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
                return []
            }

            var results: [SubtitleSearchResult] = []
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
                    displayTitle = String(format: "S%02dE%02d (Ep %d) • %@", max(1, s), e, e, movieName)
                } else if let e = eNum, e > 0 {
                    displayTitle = "Ep \(e) • \(movieName)"
                } else {
                    displayTitle = movieName
                }

                results.append(
                    SubtitleSearchResult(
                        id: id,
                        title: displayTitle,
                        releaseName: release,
                        language: lang,
                        downloadCount: dlCount,
                        downloadUrl: dlLink,
                        season: sNum,
                        episode: eNum
                    )
                )
            }

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

    /// Downloads and parses English .srt subtitle file.
    func downloadSRT(from result: SubtitleSearchResult) async -> DownloadedSubtitle? {
        guard let dlUrlString = result.downloadUrl else { return nil }

        isDownloading = true
        statusMessage = "Downloading subtitles for \(result.title)..."
        defer { isDownloading = false }

        // Attempt 1: Direct uncompressed .srt URL
        let plainSrtUrl = dlUrlString
            .replacingOccurrences(of: "http://", with: "https://")
            .replacingOccurrences(of: "/filead/", with: "/file/")
            .replacingOccurrences(of: ".gz", with: ".srt")

        if let srt = await fetchAndParseSRT(urlString: plainSrtUrl) {
            statusMessage = "Loaded \(srt.count) English lines for \(result.title)!"
            return DownloadedSubtitle(title: result.title, cues: srt)
        }

        // Attempt 2: Fallback to .gz and decompress
        let gzUrl = dlUrlString.replacingOccurrences(of: "http://", with: "https://")
        if let srt = await fetchAndParseSRT(urlString: gzUrl, decompressGzip: true) {
            statusMessage = "Loaded \(srt.count) English lines for \(result.title)!"
            return DownloadedSubtitle(title: result.title, cues: srt)
        }

        statusMessage = "Could not download or decode subtitle."
        return nil
    }

    private func fetchAndParseSRT(urlString: String, decompressGzip: Bool = false) async -> [SubtitleCue]? {
        guard let url = URL(string: urlString) else { return nil }
        var request = URLRequest(url: url)
        request.timeoutInterval = 12
        request.setValue("TemporaryUserAgent", forHTTPHeaderField: "User-Agent")

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
                return nil
            }

            var text: String?
            if decompressGzip {
                if let unzipped = data.gunzipped() {
                    text = String(data: unzipped, encoding: .utf8) ?? String(decoding: unzipped, as: UTF8.self)
                }
            } else {
                text = String(data: data, encoding: .utf8) ?? String(decoding: data, as: UTF8.self)
            }

            guard let text, !text.isEmpty else { return nil }
            let cues = SRTParser.parse(content: text)
            return cues.isEmpty ? nil : cues
        } catch {
            return nil
        }
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
