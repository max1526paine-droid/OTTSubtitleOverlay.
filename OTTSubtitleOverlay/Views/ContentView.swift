import SwiftUI
import UIKit
import UniformTypeIdentifiers

struct ContentView: View {
    @ObservedObject var pipManager = PiPSubtitleManager.shared
    @ObservedObject var syncEngine = SubtitleSyncEngine.shared
    @ObservedObject var openSubtitles = OpenSubtitlesService.shared

    @State private var searchQuery: String = ""
    @State private var seasonNumber: String = ""
    @State private var episodeNumber: String = ""
    @State private var scriptFilterText: String = ""
    @State private var downloadingItemId: String? = nil
    @State private var detectedClipboardTitle: String? = nil
    @State private var showingFileImporter: Bool = false

    private var filteredCues: [SubtitleCue] {
        let all = syncEngine.currentTrack.cues
        let q = scriptFilterText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else {
            // Show window around active cue or first 80 cues for smooth scrolling
            if let active = syncEngine.activeCue,
               let idx = all.firstIndex(where: { $0.id == active.id }) {
                let start = max(0, idx - 5)
                let end = min(all.count, start + 60)
                return Array(all[start..<end])
            }
            return Array(all.prefix(60))
        }
        return all.filter { $0.translatedText.localizedCaseInsensitiveContains(q) }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 14) {
                    // 1. Live PiP Subtitle Preview + Float Button + Quick OTT Launchers
                    VStack(spacing: 10) {
                        PiPVideoContainerView(displayLayer: pipManager.displayLayer)
                            .frame(height: 82)
                            .clipShape(RoundedRectangle(cornerRadius: 14))
                            .overlay(
                                RoundedRectangle(cornerRadius: 14)
                                    .stroke(pipManager.isPiPActive ? Color.green : Color.white.opacity(0.18), lineWidth: 1.5)
                            )
                            .shadow(color: .black.opacity(0.25), radius: 6, y: 3)

                        HStack(spacing: 10) {
                            Button {
                                pipManager.togglePiP()
                            } label: {
                                HStack(spacing: 6) {
                                    Image(systemName: pipManager.isPiPActive ? "pip.exit" : "pip.enter")
                                    Text(pipManager.isPiPActive ? "Stop Floating PiP" : "Float Subtitle Bar (PiP)")
                                        .font(.subheadline.weight(.bold))
                                }
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 12)
                                .background(pipManager.isPiPActive ? Color.green : Color.blue)
                                .foregroundStyle(.white)
                                .clipShape(RoundedRectangle(cornerRadius: 12))
                            }

                            Button {
                                launchApp(scheme: "nflx://", fallback: "https://www.netflix.com")
                            } label: {
                                HStack(spacing: 4) {
                                    Image(systemName: "play.tv.fill")
                                    Text("Netflix")
                                        .font(.subheadline.weight(.semibold))
                                }
                                .padding(.horizontal, 14)
                                .padding(.vertical, 12)
                                .background(Color.red.opacity(0.18))
                                .foregroundStyle(.red)
                                .clipShape(RoundedRectangle(cornerRadius: 12))
                            }

                            Button {
                                launchApp(scheme: "aiv://", fallback: "https://www.primevideo.com")
                            } label: {
                                HStack(spacing: 4) {
                                    Image(systemName: "film.fill")
                                    Text("Prime")
                                        .font(.subheadline.weight(.semibold))
                                }
                                .padding(.horizontal, 14)
                                .padding(.vertical, 12)
                                .background(Color.blue.opacity(0.18))
                                .foregroundStyle(.blue)
                                .clipShape(RoundedRectangle(cornerRadius: 12))
                            }
                        }
                    }
                    .padding()
                    .background(Color(.secondarySystemGroupedBackground))
                    .clipShape(RoundedRectangle(cornerRadius: 16))

                    // 2. Clipboard Auto-Detect Card (If user shared or copied from Netflix)
                    if let detected = detectedClipboardTitle, !detected.isEmpty {
                        HStack {
                            VStack(alignment: .leading, spacing: 3) {
                                Text("Detected from Clipboard")
                                    .font(.caption2.weight(.bold))
                                    .foregroundStyle(.blue)
                                Text("\"\(detected)\"")
                                    .font(.subheadline.weight(.semibold))
                                    .lineLimit(1)
                            }
                            Spacer()
                            Button("Find & Play") {
                                searchQuery = detected
                                triggerSearch(autoPlayTopResult: true)
                            }
                            .font(.caption.weight(.bold))
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                            .background(Color.blue)
                            .foregroundStyle(.white)
                            .clipShape(Capsule())
                        }
                        .padding(12)
                        .background(Color.blue.opacity(0.12))
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                    }

                    // 3. Active Episode Subtitle Player + Interactive Script List
                    if !syncEngine.currentTrack.cues.isEmpty {
                        VStack(alignment: .leading, spacing: 12) {
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(syncEngine.currentTrack.title)
                                        .font(.subheadline.weight(.bold))
                                        .foregroundStyle(.green)
                                        .lineLimit(1)
                                    Text("\(syncEngine.currentTrack.cues.count) real English lines loaded • Total: \(SRTParser.formatTime(syncEngine.currentTrack.totalDuration))")
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                Button {
                                    syncEngine.togglePlayPause()
                                    if syncEngine.isPlaying {
                                        pipManager.startPiPIfNeeded()
                                    }
                                } label: {
                                    HStack(spacing: 4) {
                                        Image(systemName: syncEngine.isPlaying ? "pause.fill" : "play.fill")
                                        Text(syncEngine.isPlaying ? "Pause" : "Play")
                                            .font(.caption.weight(.bold))
                                    }
                                    .padding(.horizontal, 12)
                                    .padding(.vertical, 8)
                                    .background(Color.blue)
                                    .foregroundStyle(.white)
                                    .clipShape(Capsule())
                                }
                            }

                            // Quick Line Jump Buttons (Prev Line / Next Line / First Dialogue / 00:00)
                            HStack(spacing: 8) {
                                Button {
                                    syncEngine.skipToPreviousCue()
                                } label: {
                                    Label("Prev Line", systemImage: "backward.end.fill")
                                        .font(.caption.weight(.bold))
                                        .frame(maxWidth: .infinity)
                                        .padding(.vertical, 9)
                                        .background(Color.blue.opacity(0.18))
                                        .foregroundStyle(.blue)
                                        .clipShape(RoundedRectangle(cornerRadius: 10))
                                }
                                .buttonStyle(.plain)

                                Button {
                                    syncEngine.skipToNextCue()
                                } label: {
                                    Label("Next Line", systemImage: "forward.end.fill")
                                        .font(.caption.weight(.bold))
                                        .frame(maxWidth: .infinity)
                                        .padding(.vertical, 9)
                                        .background(Color.blue.opacity(0.18))
                                        .foregroundStyle(.blue)
                                        .clipShape(RoundedRectangle(cornerRadius: 10))
                                }
                                .buttonStyle(.plain)

                                Button {
                                    syncEngine.jumpToFirstDialogue()
                                } label: {
                                    Text("1st Line")
                                        .font(.caption.weight(.bold))
                                        .padding(.horizontal, 10)
                                        .padding(.vertical, 9)
                                        .background(Color(.tertiarySystemFill))
                                        .clipShape(RoundedRectangle(cornerRadius: 10))
                                }
                                .buttonStyle(.plain)

                                Button {
                                    syncEngine.jumpToStartOfEpisode()
                                } label: {
                                    Text("00:00")
                                        .font(.caption.weight(.bold))
                                        .padding(.horizontal, 10)
                                        .padding(.vertical, 9)
                                        .background(Color(.tertiarySystemFill))
                                        .clipShape(RoundedRectangle(cornerRadius: 10))
                                }
                                .buttonStyle(.plain)
                            }

                            // Timeline Scrubber
                            Slider(
                                value: Binding(
                                    get: { syncEngine.currentTime },
                                    set: { syncEngine.seek(to: $0) }
                                ),
                                in: 0...max(1, syncEngine.currentTrack.totalDuration)
                            )

                            HStack {
                                Text(SRTParser.formatTime(syncEngine.currentTime))
                                Spacer()
                                Text("Tip: Tap ↺10 / ↻10 inside PiP over Netflix to jump lines!")
                                    .font(.system(size: 10, weight: .medium))
                                    .foregroundStyle(.blue)
                                Spacer()
                                Text(SRTParser.formatTime(syncEngine.currentTrack.totalDuration))
                            }
                            .font(.caption2)
                            .foregroundStyle(.secondary)

                            // Interactive Episode Script List (Tap Any Line You Hear on Netflix to Sync Instantly!)
                            Divider()

                            Text("Episode Dialogue Script (Tap any line you hear on Netflix to sync)")
                                .font(.caption.weight(.bold))
                                .foregroundStyle(.secondary)

                            TextField("Search spoken words in this episode (e.g. Ms. Choi)...", text: $scriptFilterText)
                                .textFieldStyle(.roundedBorder)
                                .font(.caption)

                            ScrollView {
                                LazyVStack(alignment: .leading, spacing: 6) {
                                    ForEach(filteredCues) { cue in
                                        let isCurrent = (syncEngine.activeCue?.id == cue.id)
                                        Button {
                                            syncEngine.jumpToCue(cue)
                                            pipManager.startPiPIfNeeded()
                                        } label: {
                                            HStack(alignment: .top, spacing: 8) {
                                                Text(SRTParser.formatTime(cue.startTime))
                                                    .font(.caption2.monospacedDigit().weight(.bold))
                                                    .foregroundStyle(isCurrent ? .yellow : .secondary)
                                                    .frame(width: 44, alignment: .leading)

                                                Text(cue.translatedText)
                                                    .font(.caption.weight(isCurrent ? .bold : .regular))
                                                    .foregroundStyle(isCurrent ? .yellow : .primary)
                                                    .multilineTextAlignment(.leading)

                                                Spacer()

                                                if isCurrent {
                                                    Image(systemName: "speaker.wave.2.fill")
                                                        .font(.caption2)
                                                        .foregroundStyle(.yellow)
                                                }
                                            }
                                            .padding(.horizontal, 10)
                                            .padding(.vertical, 7)
                                            .background(isCurrent ? Color.blue.opacity(0.28) : Color(.tertiarySystemGroupedBackground))
                                            .clipShape(RoundedRectangle(cornerRadius: 8))
                                        }
                                        .buttonStyle(.plain)
                                    }
                                }
                            }
                            .frame(maxHeight: 210)
                        }
                        .padding()
                        .background(Color(.secondarySystemGroupedBackground))
                        .clipShape(RoundedRectangle(cornerRadius: 16))
                    }

                    // 4. Search Any Movie / Show on the Web
                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            Label("Find Movie or Series Subtitles", systemImage: "magnifyingglass")
                                .font(.subheadline.weight(.semibold))
                            Spacer()
                            Button {
                                showingFileImporter = true
                            } label: {
                                Label("Import .SRT", systemImage: "folder")
                                    .font(.caption2.weight(.bold))
                            }
                        }

                        HStack(spacing: 8) {
                            TextField("Show name (e.g. Teach you a lesson ep 6)...", text: $searchQuery)
                                .textFieldStyle(.roundedBorder)
                                .onSubmit {
                                    triggerSearch(autoPlayTopResult: true)
                                }
                            TextField("S", text: $seasonNumber)
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 38)
                                .keyboardType(.numberPad)
                            TextField("E", text: $episodeNumber)
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 38)
                                .keyboardType(.numberPad)
                        }

                        Button {
                            triggerSearch(autoPlayTopResult: true)
                        } label: {
                            HStack(spacing: 8) {
                                if openSubtitles.isSearching || openSubtitles.isDownloading {
                                    ProgressView().controlSize(.small)
                                } else {
                                    Image(systemName: "play.fill")
                                }
                                Text(openSubtitles.isSearching ? "Searching..." : (openSubtitles.isDownloading ? "Downloading Episode SRT..." : "Find & Play English Subtitles"))
                                    .font(.subheadline.weight(.bold))
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 12)
                            .background(Color.blue)
                            .foregroundStyle(.white)
                            .clipShape(RoundedRectangle(cornerRadius: 12))
                        }
                        .disabled(openSubtitles.isSearching || openSubtitles.isDownloading)

                        if !openSubtitles.statusMessage.isEmpty {
                            Text(openSubtitles.statusMessage)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }

                        // Search Results List
                        ForEach(openSubtitles.searchResults) { item in
                            Button {
                                selectResult(item)
                            } label: {
                                HStack {
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(item.title)
                                            .font(.subheadline.weight(.bold))
                                            .foregroundStyle(.primary)
                                            .lineLimit(1)
                                        Text(item.releaseName)
                                            .font(.caption2)
                                            .foregroundStyle(.secondary)
                                            .lineLimit(1)
                                    }
                                    Spacer()
                                    if downloadingItemId == item.id {
                                        ProgressView().controlSize(.small)
                                            .padding(.horizontal, 10)
                                    } else {
                                        VStack(alignment: .trailing, spacing: 2) {
                                            Text("Play SRT")
                                                .font(.caption2.weight(.bold))
                                                .padding(.horizontal, 10)
                                                .padding(.vertical, 5)
                                                .background(Color.blue)
                                                .foregroundStyle(.white)
                                                .clipShape(Capsule())
                                            if item.downloadCount > 0 {
                                                Text("\(item.downloadCount) DLs")
                                                    .font(.system(size: 9))
                                                    .foregroundStyle(.secondary)
                                            }
                                        }
                                    }
                                }
                                .padding(12)
                                .background(Color(.tertiarySystemGroupedBackground))
                                .clipShape(RoundedRectangle(cornerRadius: 12))
                            }
                            .buttonStyle(.plain)
                            .disabled(downloadingItemId != nil)
                        }
                    }
                    .padding()
                    .background(Color(.secondarySystemGroupedBackground))
                    .clipShape(RoundedRectangle(cornerRadius: 16))
                }
                .padding(.horizontal)
                .padding(.bottom, 24)
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("SubFloat OTT v3.0")
            .navigationBarTitleDisplayMode(.inline)
            .onAppear {
                checkClipboardForNetflixTitle()
            }
            .fileImporter(
                isPresented: $showingFileImporter,
                allowedContentTypes: [.plainText, .text, UTType(filenameExtension: "srt") ?? .plainText],
                allowsMultipleSelection: false
            ) { result in
                if case .success(let urls) = result, let url = urls.first {
                    let accessed = url.startAccessingSecurityScopedResource()
                    defer { if accessed { url.stopAccessingSecurityScopedResource() } }
                    if let content = try? String(contentsOf: url, encoding: .utf8) {
                        syncEngine.importSRTFileContent(content, fileName: url.lastPathComponent, sourceLanguage: .korean)
                        syncEngine.play()
                        pipManager.startPiPIfNeeded()
                    }
                }
            }
        }
    }

    private func triggerSearch(autoPlayTopResult: Bool = true) {
        let q = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return }
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
        Task {
            await openSubtitles.searchSubtitles(query: q, season: seasonNumber, episode: episodeNumber)
            if autoPlayTopResult, let first = openSubtitles.searchResults.first {
                selectResult(first)
            }
        }
    }

    private func selectResult(_ item: OpenSubtitleSearchResult) {
        if let track = item.embeddedTrack {
            syncEngine.loadTrack(track, startAtFirstDialogue: true)
            syncEngine.play()
            pipManager.startPiPIfNeeded()
        } else if item.downloadUrl != nil {
            downloadingItemId = item.id
            Task {
                defer { downloadingItemId = nil }
                if let downloaded = await openSubtitles.downloadSRT(from: item) {
                    let track = SubtitleTrack(
                        id: UUID(),
                        title: downloaded.title,
                        sourceLanguage: .korean,
                        cues: downloaded.cues
                    )
                    syncEngine.loadTrack(track, startAtFirstDialogue: true)
                    syncEngine.play()
                    pipManager.startPiPIfNeeded()
                }
            }
        }
    }

    private func checkClipboardForNetflixTitle() {
        guard let clip = UIPasteboard.general.string?.trimmingCharacters(in: .whitespacesAndNewlines),
              !clip.isEmpty else { return }

        if let watchRange = clip.range(of: "Watch ", options: .caseInsensitive),
           let pipeRange = clip.range(of: "|", range: watchRange.upperBound..<clip.endIndex) {
            let extracted = String(clip[watchRange.upperBound..<pipeRange.lowerBound]).trimmingCharacters(in: .whitespaces)
            if !extracted.isEmpty {
                self.detectedClipboardTitle = extracted
                return
            }
        }
        if clip.count >= 3 && clip.count <= 45 && !clip.hasPrefix("http") {
            self.detectedClipboardTitle = clip
        }
    }

    private func launchApp(scheme: String, fallback: String) {
        pipManager.startPiPIfNeeded()
        if !syncEngine.currentTrack.cues.isEmpty && !syncEngine.isPlaying {
            syncEngine.play()
        }
        if let url = URL(string: scheme), UIApplication.shared.canOpenURL(url) {
            UIApplication.shared.open(url)
        } else if let url = URL(string: fallback) {
            UIApplication.shared.open(url)
        }
    }
}
