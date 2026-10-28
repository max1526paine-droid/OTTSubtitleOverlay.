import SwiftUI
import UniformTypeIdentifiers

struct SubtitleSyncTabView: View {
    @ObservedObject var syncEngine = SubtitleSyncEngine.shared
    @ObservedObject var openSubtitles = OpenSubtitlesService.shared
    @ObservedObject var pipManager = PiPSubtitleManager.shared

    @State private var searchQuery: String = ""
    @State private var seasonNumber: String = ""
    @State private var episodeNumber: String = ""
    @State private var showingFileImporter: Bool = false
    @State private var importLanguage: SourceLanguage = .korean

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                // 1. Active Subtitle Track & Sync Player Card
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(syncEngine.currentTrack.title)
                                .font(.subheadline.weight(.bold))
                                .lineLimit(1)
                            Text("\(syncEngine.currentTrack.sourceLanguage.flagEmoji) \(syncEngine.currentTrack.cues.count) cues • Total \(SRTParser.formatTime(syncEngine.currentTrack.totalDuration))")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button {
                            syncEngine.togglePlayPause()
                            if syncEngine.isPlaying {
                                pipManager.startPiPIfNeeded()
                            }
                        } label: {
                            HStack(spacing: 6) {
                                Image(systemName: syncEngine.isPlaying ? "pause.fill" : "play.fill")
                                Text(syncEngine.isPlaying ? "Pause Sync" : "Play in PiP")
                                    .font(.subheadline.weight(.semibold))
                            }
                            .padding(.horizontal, 14)
                            .padding(.vertical, 8)
                            .background(Color.accentColor)
                            .foregroundStyle(.white)
                            .clipShape(Capsule())
                        }
                    }

                    // Timeline Scrubber
                    VStack(spacing: 4) {
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
                                .fontWeight(.semibold)
                                .foregroundStyle(syncEngine.syncOffsetSeconds == 0 ? .secondary : Color.accentColor)
                            Spacer()
                            Text(SRTParser.formatTime(syncEngine.currentTrack.totalDuration))
                        }
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    }

                    // Precision Sync Offset Nudge Buttons
                    HStack(spacing: 8) {
                        ForEach([-1.0, -0.25, 0.25, 1.0], id: \.self) { delta in
                            Button {
                                syncEngine.adjustSyncOffset(by: delta)
                            } label: {
                                Text(String(format: "%+.2fs", delta))
                                    .font(.caption.weight(.semibold))
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, 8)
                                    .background(Color(.tertiarySystemFill))
                                    .clipShape(RoundedRectangle(cornerRadius: 8))
                            }
                            .buttonStyle(.plain)
                        }
                    }

                    // AI Translate Entire Foreign SRT Track Button
                    Button {
                        Task {
                            await syncEngine.translateLoadedTrackToEnglish()
                        }
                    } label: {
                        HStack {
                            if syncEngine.isTranslatingTrack {
                                ProgressView()
                                    .controlSize(.small)
                                Text("Translating Track (\(Int(syncEngine.translationProgress * 100))%)...")
                            } else {
                                Image(systemName: "sparkles")
                                Text("AI Translate Track to English (ChatGPT → Gemini 3.8)")
                            }
                        }
                        .font(.caption.weight(.semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 9)
                        .background(Color.purple.opacity(0.15))
                        .foregroundStyle(.purple)
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                    }
                    .disabled(syncEngine.isTranslatingTrack)
                }
                .padding()
                .background(Color(.secondarySystemGroupedBackground))
                .clipShape(RoundedRectangle(cornerRadius: 16))

                // 2. Import Local .SRT / .VTT File or Search OpenSubtitles
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Label("Search or Import Subtitles", systemImage: "magnifyingglass")
                            .font(.subheadline.weight(.semibold))
                        Spacer()
                        Button {
                            showingFileImporter = true
                        } label: {
                            Label("Import .SRT/.VTT", systemImage: "folder.badge.plus")
                                .font(.caption.weight(.semibold))
                                .padding(.horizontal, 10)
                                .padding(.vertical, 6)
                                .background(Color(.tertiarySystemFill))
                                .clipShape(Capsule())
                        }
                    }

                    HStack(spacing: 8) {
                        TextField("Movie / Show title (e.g. Squid Game, One Piece)...", text: $searchQuery)
                            .textFieldStyle(.roundedBorder)
                        TextField("S", text: $seasonNumber)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 44)
                            .keyboardType(.numberPad)
                        TextField("E", text: $episodeNumber)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 44)
                            .keyboardType(.numberPad)
                        Button {
                            Task {
                                await openSubtitles.searchSubtitles(
                                    query: searchQuery,
                                    season: seasonNumber,
                                    episode: episodeNumber
                                )
                            }
                        } label: {
                            Image(systemName: "arrow.right.circle.fill")
                                .font(.title2)
                        }
                    }

                    ForEach(openSubtitles.searchResults) { item in
                        Button {
                            if let track = item.embeddedTrack {
                                syncEngine.loadTrack(track)
                                syncEngine.play()
                                pipManager.startPiPIfNeeded()
                            }
                        } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(item.title)
                                        .font(.subheadline.weight(.semibold))
                                        .foregroundStyle(.primary)
                                    Text(item.releaseName)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                Text(item.language)
                                    .font(.caption2.weight(.bold))
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 4)
                                    .background(Color.accentColor.opacity(0.15))
                                    .clipShape(Capsule())
                            }
                            .padding(10)
                            .background(Color(.tertiarySystemGroupedBackground))
                            .clipShape(RoundedRectangle(cornerRadius: 10))
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
        .fileImporter(
            isPresented: $showingFileImporter,
            allowedContentTypes: [.plainText, .text, UTType(filenameExtension: "srt") ?? .plainText],
            allowsMultipleSelection: false
        ) { result in
            if case .success(let urls) = result, let url = urls.first {
                let accessed = url.startAccessingSecurityScopedResource()
                defer {
                    if accessed { url.stopAccessingSecurityScopedResource() }
                }
                if let content = try? String(contentsOf: url, encoding: .utf8) {
                    syncEngine.importSRTFileContent(
                        content,
                        fileName: url.lastPathComponent,
                        sourceLanguage: importLanguage
                    )
                }
            }
        }
    }
}
