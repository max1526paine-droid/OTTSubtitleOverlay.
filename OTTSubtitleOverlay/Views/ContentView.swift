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
    @State private var detectedClipboardTitle: String? = nil
    @State private var showingFileImporter: Bool = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 14) {
                    // 1. Live PiP Subtitle Preview + Float Button
                    VStack(spacing: 10) {
                        PiPVideoContainerView(displayLayer: pipManager.displayLayer)
                            .frame(height: 78)
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

                            // Quick OTT Launchers
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
                                Text("Detected from Netflix")
                                    .font(.caption2.weight(.bold))
                                    .foregroundStyle(.blue)
                                Text("\"\(detected)\"")
                                    .font(.subheadline.weight(.semibold))
                                    .lineLimit(1)
                            }
                            Spacer()
                            Button("Load Subtitles") {
                                searchQuery = detected
                                Task {
                                    await openSubtitles.searchSubtitles(query: detected)
                                }
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

                    // 3. Active Playback & Sync Timing Controls
                    if !syncEngine.currentTrack.cues.isEmpty {
                        VStack(alignment: .leading, spacing: 10) {
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(syncEngine.currentTrack.title)
                                        .font(.subheadline.weight(.bold))
                                        .lineLimit(1)
                                    Text("\(syncEngine.currentTrack.cues.count) dialogue lines • Duration: \(SRTParser.formatTime(syncEngine.currentTrack.totalDuration))")
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
                                    Image(systemName: syncEngine.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                                        .font(.title)
                                        .foregroundStyle(Color.blue)
                                }
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
                                Text(String(format: "Sync Offset: %+.2fs", syncEngine.syncOffsetSeconds))
                                    .fontWeight(.bold)
                                    .foregroundStyle(syncEngine.syncOffsetSeconds == 0 ? .secondary : Color.blue)
                                Spacer()
                                Text(SRTParser.formatTime(syncEngine.currentTrack.totalDuration))
                            }
                            .font(.caption2)
                            .foregroundStyle(.secondary)

                            // Precision Sync Nudge Buttons
                            HStack(spacing: 8) {
                                ForEach([-1.0, -0.25, 0.25, 1.0], id: \.self) { delta in
                                    Button {
                                        syncEngine.adjustSyncOffset(by: delta)
                                    } label: {
                                        Text(String(format: "%+.2fs", delta))
                                            .font(.caption.weight(.bold))
                                            .frame(maxWidth: .infinity)
                                            .padding(.vertical, 8)
                                            .background(Color(.tertiarySystemFill))
                                            .clipShape(RoundedRectangle(cornerRadius: 8))
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
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
                            TextField("Enter show title (e.g. Teach You a Lesson)...", text: $searchQuery)
                                .textFieldStyle(.roundedBorder)
                                .onSubmit {
                                    triggerSearch()
                                }
                            TextField("S", text: $seasonNumber)
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 42)
                                .keyboardType(.numberPad)
                            TextField("E", text: $episodeNumber)
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 42)
                                .keyboardType(.numberPad)

                            Button {
                                triggerSearch()
                            } label: {
                                if openSubtitles.isSearching {
                                    ProgressView().controlSize(.small)
                                        .frame(width: 32, height: 32)
                                } else {
                                    Image(systemName: "arrow.right.circle.fill")
                                        .font(.title2)
                                        .foregroundStyle(Color.blue)
                                }
                            }
                            .disabled(openSubtitles.isSearching)
                        }

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
                                            .font(.subheadline.weight(.semibold))
                                            .foregroundStyle(.primary)
                                            .lineLimit(1)
                                        Text(item.releaseName)
                                            .font(.caption2)
                                            .foregroundStyle(.secondary)
                                            .lineLimit(1)
                                    }
                                    Spacer()
                                    VStack(alignment: .trailing, spacing: 2) {
                                        Text(item.language)
                                            .font(.caption2.weight(.bold))
                                            .padding(.horizontal, 8)
                                            .padding(.vertical, 4)
                                            .background(Color.blue.opacity(0.15))
                                            .clipShape(Capsule())
                                        if item.downloadCount > 0 {
                                            Text("\(item.downloadCount) DLs")
                                                .font(.system(size: 9))
                                                .foregroundStyle(.secondary)
                                        }
                                    }
                                }
                                .padding(12)
                                .background(Color(.tertiarySystemGroupedBackground))
                                .clipShape(RoundedRectangle(cornerRadius: 12))
                            }
                            .buttonStyle(.plain)
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
            .navigationTitle("SubFloat OTT")
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

    private func triggerSearch() {
        let q = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return }
        Task {
            await openSubtitles.searchSubtitles(query: q, season: seasonNumber, episode: episodeNumber)
        }
    }

    private func selectResult(_ item: OpenSubtitleSearchResult) {
        if let track = item.embeddedTrack {
            syncEngine.loadTrack(track)
            syncEngine.play()
            pipManager.startPiPIfNeeded()
        } else if item.downloadUrl != nil {
            Task {
                if let downloaded = await openSubtitles.downloadSRT(from: item) {
                    let track = SubtitleTrack(
                        id: UUID(),
                        title: downloaded.title,
                        sourceLanguage: .korean,
                        cues: downloaded.cues
                    )
                    syncEngine.loadTrack(track)
                    syncEngine.play()
                    pipManager.startPiPIfNeeded()
                }
            }
        }
    }

    private func checkClipboardForNetflixTitle() {
        guard let clip = UIPasteboard.general.string?.trimmingCharacters(in: .whitespacesAndNewlines),
              !clip.isEmpty else { return }
        
        // 1. Netflix Share Format: "Watch Teach You a Lesson | Netflix https://..."
        if let watchRange = clip.range(of: "Watch ", options: .caseInsensitive),
           let pipeRange = clip.range(of: "|", range: watchRange.upperBound..<clip.endIndex) {
            let extracted = String(clip[watchRange.upperBound..<pipeRange.lowerBound]).trimmingCharacters(in: .whitespaces)
            if !extracted.isEmpty {
                self.detectedClipboardTitle = extracted
                return
            }
        }
        // 2. Short title pasted into clipboard
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
