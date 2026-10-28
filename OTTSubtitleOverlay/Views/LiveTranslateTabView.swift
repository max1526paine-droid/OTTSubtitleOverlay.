import SwiftUI

struct LiveTranslateTabView: View {
    @ObservedObject var liveTranslator = LiveAudioTranslator.shared
    @ObservedObject var translationService = TranslationService.shared
    @ObservedObject var pipManager = PiPSubtitleManager.shared
    @ObservedObject var syncEngine = SubtitleSyncEngine.shared
    @ObservedObject var openSubtitles = OpenSubtitlesService.shared

    @State private var srtQuery: String = ""
    @State private var srtSeason: String = ""
    @State private var srtEpisode: String = ""

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                // 1. Source Language & AI Provider Failover Status Card
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Label("Source Audio Language", systemImage: "globe.asia.australia.fill")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.secondary)
                        Spacer()
                        HStack(spacing: 6) {
                            Circle()
                                .fill(translationService.activeProvider.badgeColor)
                                .frame(width: 8, height: 8)
                            Text(translationService.activeProvider.shortBadge)
                                .font(.caption.weight(.bold))
                                .foregroundStyle(translationService.activeProvider.badgeColor)
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(translationService.activeProvider.badgeColor.opacity(0.15))
                        .clipShape(Capsule())
                    }

                    Picker("Source Language", selection: $liveTranslator.sourceLanguage) {
                        ForEach(SourceLanguage.allCases) { lang in
                            Text("\(lang.flagEmoji) \(lang.displayName) → English")
                                .tag(lang)
                        }
                    }
                    .pickerStyle(.menu)
                    .tint(.primary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
                    .background(Color(.tertiarySystemFill))
                    .clipShape(RoundedRectangle(cornerRadius: 10))

                    if let failoverNotice = translationService.lastFailoverNotice {
                        HStack(spacing: 8) {
                            Image(systemName: "arrow.triangle.2.circlepath.circle.fill")
                                .foregroundStyle(.orange)
                            Text("Auto-Failover: \(failoverNotice)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Spacer()
                            Button("Reset") {
                                translationService.resetQuotaFlags()
                            }
                            .font(.caption.weight(.semibold))
                        }
                        .padding(8)
                        .background(Color.orange.opacity(0.12))
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                    }
                }
                .padding()
                .background(Color(.secondarySystemGroupedBackground))
                .clipShape(RoundedRectangle(cornerRadius: 16))

                // 2. Live Capture Controls (Microphone / Speaker + ReplayKit System Audio)
                VStack(spacing: 12) {
                    Button {
                        liveTranslator.toggleListening()
                        if !pipManager.isPiPActive {
                            pipManager.startPiPIfNeeded()
                        }
                    } label: {
                        HStack(spacing: 10) {
                            Image(systemName: liveTranslator.isListening ? "stop.circle.fill" : "mic.fill")
                                .font(.title3)
                            Text(liveTranslator.isListening ? "Stop Live Audio Translation" : "Start Live Audio Translation + PiP")
                                .font(.headline)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                        .background(liveTranslator.isListening ? Color.red : Color.accentColor)
                        .foregroundStyle(.white)
                        .clipShape(RoundedRectangle(cornerRadius: 14))
                    }

                    HStack(spacing: 12) {
                        SystemBroadcastPickerRepresentable(
                            preferredExtensionBundleID: "com.irshad.ottsubtitleoverlay.BroadcastExtension"
                        )
                        .frame(width: 42, height: 42)
                        .background(Color(.tertiarySystemFill))
                        .clipShape(Circle())

                        VStack(alignment: .leading, spacing: 2) {
                            Text("System Audio Capture (ReplayKit)")
                                .font(.subheadline.weight(.semibold))
                            Text(liveTranslator.isBroadcastActive
                                 ? "Receiving internal OTT audio via App Group"
                                 : "Tap the broadcast icon to capture internal app audio directly")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                    }
                    .padding(10)
                    .background(Color(.tertiarySystemGroupedBackground))
                    .clipShape(RoundedRectangle(cornerRadius: 12))

                    HStack {
                        Image(systemName: "waveform")
                            .foregroundStyle(liveTranslator.isListening ? .green : .secondary)
                        Text(liveTranslator.statusMessage)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                    }
                }
                .padding()
                .background(Color(.secondarySystemGroupedBackground))
                .clipShape(RoundedRectangle(cornerRadius: 16))

                // 2b. Wrong translation? Download the real .srt for the show and play it
                VStack(alignment: .leading, spacing: 10) {
                    Label("Wrong translation? Use real subtitles (SRT)", systemImage: "captions.bubble.fill")
                        .font(.subheadline.weight(.semibold))

                    Text("Type the show name you are watching. The app downloads its real English .srt from OpenSubtitles and plays it in the PiP bar. Live audio keeps the timing aligned.")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    HStack(spacing: 8) {
                        TextField("Show / movie name", text: $srtQuery)
                            .textFieldStyle(.roundedBorder)
                        TextField("S", text: $srtSeason)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 44)
                            .keyboardType(.numberPad)
                        TextField("E", text: $srtEpisode)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 44)
                            .keyboardType(.numberPad)
                    }

                    HStack(spacing: 8) {
                        Button {
                            Task {
                                await syncEngine.findAndPlaySRT(
                                    query: srtQuery,
                                    season: srtSeason,
                                    episode: srtEpisode,
                                    sourceLanguage: liveTranslator.sourceLanguage
                                )
                            }
                        } label: {
                            HStack {
                                if syncEngine.isFetchingOnline {
                                    ProgressView().controlSize(.small)
                                } else {
                                    Image(systemName: "arrow.down.circle.fill")
                                }
                                Text(syncEngine.isFetchingOnline ? "Finding subtitles..." : "Find & Play SRT")
                            }
                            .font(.subheadline.weight(.semibold))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 10)
                            .background(Color.accentColor)
                            .foregroundStyle(.white)
                            .clipShape(RoundedRectangle(cornerRadius: 10))
                        }
                        .disabled(syncEngine.isFetchingOnline)

                        if syncEngine.srtOverrideActive {
                            Button {
                                syncEngine.stopSRTOverride()
                            } label: {
                                Text("Back to Live AI")
                                    .font(.subheadline.weight(.semibold))
                                    .padding(.vertical, 10)
                                    .padding(.horizontal, 12)
                                    .background(Color(.tertiarySystemFill))
                                    .clipShape(RoundedRectangle(cornerRadius: 10))
                            }
                            .buttonStyle(.plain)
                        }
                    }

                    if syncEngine.srtOverrideActive {
                        HStack(spacing: 8) {
                            ForEach([-2.0, -0.5, 0.5, 2.0], id: \.self) { delta in
                                Button {
                                    syncEngine.adjustSyncOffset(by: delta)
                                } label: {
                                    Text(String(format: "%+.1fs", delta))
                                        .font(.caption.weight(.semibold))
                                        .frame(maxWidth: .infinity)
                                        .padding(.vertical, 8)
                                        .background(Color(.tertiarySystemFill))
                                        .clipShape(RoundedRectangle(cornerRadius: 8))
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }

                    if !syncEngine.onlineStatus.isEmpty {
                        Text(syncEngine.onlineStatus)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding()
                .background(Color(.secondarySystemGroupedBackground))
                .clipShape(RoundedRectangle(cornerRadius: 16))

                // 3. Live Dual-Subtitle Stream History
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Label("Live Translated Dialogue Feed", systemImage: "text.bubble.fill")
                            .font(.subheadline.weight(.semibold))
                        Spacer()
                        if !liveTranslator.liveHistory.isEmpty {
                            Button("Clear") {
                                liveTranslator.liveHistory.removeAll()
                            }
                            .font(.caption)
                        }
                    }

                    if liveTranslator.liveHistory.isEmpty {
                        Text("Play Korean, Japanese, or foreign dialogue on Netflix or Prime Video. Translated English lines will appear here and in the floating PiP bar.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .padding(.vertical, 12)
                    } else {
                        ForEach(liveTranslator.liveHistory.prefix(15)) { cue in
                            VStack(alignment: .leading, spacing: 4) {
                                HStack {
                                    if let orig = cue.originalText, !orig.isEmpty {
                                        Text(orig)
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    if let provider = cue.providerUsed {
                                        Text(provider)
                                            .font(.system(size: 10, weight: .semibold))
                                            .padding(.horizontal, 6)
                                            .padding(.vertical, 2)
                                            .background(Color.accentColor.opacity(0.15))
                                            .clipShape(Capsule())
                                    }
                                }
                                Text(cue.translatedText)
                                    .font(.subheadline.weight(.semibold))
                                    .foregroundStyle(.primary)
                            }
                            .padding(10)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(Color(.tertiarySystemGroupedBackground))
                            .clipShape(RoundedRectangle(cornerRadius: 10))
                        }
                    }
                }
                .padding()
                .background(Color(.secondarySystemGroupedBackground))
                .clipShape(RoundedRectangle(cornerRadius: 16))
            }
            .padding(.horizontal)
            .padding(.bottom, 24)
        }
    }
}
