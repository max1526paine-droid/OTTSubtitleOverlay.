import SwiftUI

struct SettingsTabView: View {
    @ObservedObject var translationService = TranslationService.shared
    @ObservedObject var openSubtitles = OpenSubtitlesService.shared
    @ObservedObject var pipManager = PiPSubtitleManager.shared

    var body: some View {
        Form {
            Section {
                Picker("Failover Chain", selection: $translationService.failoverOrder) {
                    ForEach(TranslationFailoverOrder.allCases) { order in
                        Text(order.rawValue).tag(order)
                    }
                }

                HStack {
                    Text("Current Active Provider")
                    Spacer()
                    Text(translationService.activeProvider.shortBadge)
                        .fontWeight(.semibold)
                        .foregroundStyle(translationService.activeProvider.badgeColor)
                }

                if translationService.chatGPTQuotaExhausted || translationService.gemini38QuotaExhausted {
                    Button("Reset Token/Quota Exhaustion Flags") {
                        translationService.resetQuotaFlags()
                    }
                    .foregroundStyle(.orange)
                }
            } header: {
                Text("AI Token Failover (ChatGPT → Gemini 3.8)")
            } footer: {
                Text("If ChatGPT tokens or rate limits end (HTTP 429/402), the app automatically switches to Gemini 3.8 (gemini-3.8-flash / gemini-3.8-live), and then to the Free Keyless Translator.")
            }

            Section {
                SecureField("OpenAI API Key (sk-...)", text: $translationService.openAIKey)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()

                SecureField("Gemini 3.8 API Key (AIza...)", text: $translationService.geminiKey)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()

                SecureField("OpenSubtitles API Key (Optional)", text: $openSubtitles.apiKey)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
            } header: {
                Text("API Keys")
            } footer: {
                Text("Leave blank to use the built-in Free Keyless Translator and sample subtitle tracks immediately.")
            }

            Section("PiP Subtitle Overlay Style") {
                Picker("Subtitle Color", selection: $pipManager.styleSettings.textColor) {
                    ForEach(SubtitleTextColor.allCases) { color in
                        Text(color.rawValue).tag(color)
                    }
                }

                VStack(alignment: .leading) {
                    Text("Subtitle Font Size: \(Int(pipManager.styleSettings.fontSize)) pt")
                        .font(.subheadline)
                    Slider(value: $pipManager.styleSettings.fontSize, in: 20...38, step: 1)
                }

                Toggle("Show Original Language Line (Dual Sub)", isOn: $pipManager.styleSettings.showOriginalLanguageLine)
                Toggle("Show Language & Provider Header in PiP", isOn: $pipManager.styleSettings.showStatusHeaderInPiP)
                Toggle("Keep Running When Backgrounded / Locked", isOn: $pipManager.styleSettings.keepActiveWhenLockedOrBackgrounded)
            }
        }
    }
}
