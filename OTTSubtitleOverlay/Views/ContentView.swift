import SwiftUI
import UIKit

struct ContentView: View {
    @ObservedObject var pipManager = PiPSubtitleManager.shared
    @ObservedObject var liveTranslator = LiveAudioTranslator.shared
    @ObservedObject var syncEngine = SubtitleSyncEngine.shared

    @State private var selectedTab: Int = 0

    var body: some View {
        NavigationStack {
            VStack(spacing: 12) {
                // 1. Live Floating PiP Subtitle Banner Preview + Quick Launch Controls
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
                            .padding(.vertical, 10)
                            .background(pipManager.isPiPActive ? Color.green : Color.indigo)
                            .foregroundStyle(.white)
                            .clipShape(RoundedRectangle(cornerRadius: 10))
                        }

                        // Quick OTT Launch Strip (Auto-Starts PiP & Opens Netflix / Prime Video)
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 8) {
                                ForEach(OTTAppShortcut.supportedApps) { app in
                                    Button {
                                        launchOTTAppWithPiP(app)
                                    } label: {
                                        HStack(spacing: 4) {
                                            Image(systemName: app.systemIcon)
                                            Text(app.name)
                                                .font(.caption.weight(.semibold))
                                        }
                                        .padding(.horizontal, 10)
                                        .padding(.vertical, 10)
                                        .background(app.accentColor.opacity(0.16))
                                        .foregroundStyle(app.accentColor)
                                        .clipShape(RoundedRectangle(cornerRadius: 10))
                                    }
                                }
                            }
                        }
                    }
                }
                .padding(.horizontal)
                .padding(.top, 6)

                // 2. Mode & Settings Tabs
                Picker("Section", selection: $selectedTab) {
                    Text("Live AI Audio").tag(0)
                    Text("SRT / Search Sync").tag(1)
                    Text("Settings & Keys").tag(2)
                }
                .pickerStyle(.segmented)
                .padding(.horizontal)

                Group {
                    switch selectedTab {
                    case 0:
                        LiveTranslateTabView()
                    case 1:
                        SubtitleSyncTabView()
                    default:
                        SettingsTabView()
                    }
                }
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("SubFloat OTT")
            .navigationBarTitleDisplayMode(.inline)
        }
    }

    private func launchOTTAppWithPiP(_ app: OTTAppShortcut) {
        pipManager.startPiPIfNeeded()
        if selectedTab == 0 && !liveTranslator.isListening {
            liveTranslator.toggleListening()
        } else if selectedTab == 1 && !syncEngine.isPlaying {
            syncEngine.play()
        }

        if let schemeURL = URL(string: app.urlScheme),
           UIApplication.shared.canOpenURL(schemeURL) {
            UIApplication.shared.open(schemeURL)
        } else if let webURL = URL(string: app.fallbackWebURL) {
            UIApplication.shared.open(webURL)
        }
    }
}
