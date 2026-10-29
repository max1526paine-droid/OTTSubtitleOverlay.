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

    @Published var apiKey: String = ""
    @Published var isSearching: Bool = false
    @Published var isDownloading: Bool = false
    @Published var searchResults: [OpenSubtitleSearchResult] = []
    @Published var statusMessage: String = ""
    @Published var errorMessage: String?

    init() {
        self.searchResults = []
    }

    // MARK: - Keyless Web Subtitle Scourer (Free & Open REST API)

    struct DownloadedSRT {
        let title: String
        let languageCode: String
        let cues: [SubtitleCue]
    }

    /// Searches public subtitle mirrors on the web for any movie or TV series title.
    func searchSubtitles(query: String, season: String = "", episode: String = "") async {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            searchResults = []
            statusMessage = ""
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
            self.searchResults = []
            self.statusMessage = "No subtitles found for \"\(trimmed)\". Please check show name."
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
                var dlLink = (item["SubDownloadLink"] as? String) ?? ""
                if dlLink.hasPrefix("http://") {
                    dlLink = dlLink.replacingOccurrences(of: "http://", with: "https://")
                }
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
        guard var dlUrlString = result.downloadUrl else { return nil }
        if dlUrlString.hasPrefix("http://") {
            dlUrlString = dlUrlString.replacingOccurrences(of: "http://", with: "https://")
        }
        guard let url = URL(string: dlUrlString) else { return nil }

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
