# SubFloat (`OTTSubtitleOverlay`) — iOS Floating Subtitle Overlay for Netflix, Prime Video & OTT Apps

**SubFloat** is a native iOS (SwiftUI) application that renders real-time English subtitles (from **Korean**, **Japanese**, **Chinese**, **Spanish**, **Hindi**, and more) inside an **iOS Picture-in-Picture (PiP) floating banner** on top of **Netflix**, **Amazon Prime Video**, **Crunchyroll**, **Disney+**, and **Viki**.

---

## Key Architecture & Features

### 1. Floating Picture-in-Picture (PiP) Subtitle Bar (`PiPSubtitleManager.swift`)
- Uses `AVPictureInPictureController` with `AVSampleBufferDisplayLayer` to render a wide cinema banner (`1280x260`) that floats on top of any OTT app.
- Configures `AVAudioSession` with `.mixWithOthers` so starting or updating the PiP subtitle overlay **never pauses Netflix or Amazon Prime Video**.
- Supports PiP transport controls: tapping `-10s` / `+10s` directly inside the floating PiP window nudges subtitle timing by `-0.5s` / `+0.5s` without leaving Netflix.
- Continues running even when backgrounded or when the system screen is locked (`UIBackgroundModes: audio, fetch, processing` + `beginBackgroundTask`).

### 2. Resilient AI Translation Failover Chain (`TranslationService.swift` & `GeminiLiveWebSocketClient.swift`)
- **Primary**: **ChatGPT (`gpt-4o-mini`)** with OTT K-Drama / Anime honorific and idiom context awareness.
- **Automatic Failover 1**: **Google Gemini 3.8 (`gemini-3.8-flash`)** via the official `/v1beta2/interactions` REST API, plus **Gemini Live (`gemini-3.5-live-translate-preview` / `gemini-3.8-live`)** via WebSockets for 16kHz PCM audio streaming.
- **Automatic Failover 2**: **Free Keyless Translator (`MyMemory` REST API)** so subtitles never stop mid-episode even if both ChatGPT and Gemini tokens/quotas run out (`HTTP 429` / `402`).

### 3. Dual Subtitle Modes
- **Mode A — Live AI Audio Translation (`LiveAudioTranslator.swift` + `BroadcastExtension/SampleHandler.swift`)**:
  - Listens to foreign dialogue via Microphone/Speaker or **ReplayKit System Audio Broadcast (`.audioApp`)** and translates into English in real time.
- **Mode B — `.SRT` / `.VTT` File & OpenSubtitles Sync (`SubtitleSyncEngine.swift` + `SRTParser.swift`)**:
  - Load built-in K-Drama/Anime tracks, search **OpenSubtitles REST API v1**, or import `.srt` / `.vtt` files from the iPhone Files app.
  - Includes a **1-Tap AI Translate Track** button to translate foreign `.srt` files into dual-language English subtitles.

---

## How to Build & Install on iPhone (From Windows or Mac)

### Option A: Build on Windows via GitHub Actions (No Mac Required)
1. Push this folder (`OTTSubtitleOverlay`) to a private or public GitHub repository.
2. GitHub Actions automatically runs [`.github/workflows/build-ios-ipa.yml`](.github/workflows/build-ios-ipa.yml) on a macOS runner (`xcodegen` + `xcodebuild`) and produces `SubFloat-OTTSubtitleOverlay.ipa`.
3. Download the `.ipa` artifact from the **Actions** tab on GitHub and install it onto your iPhone using **Sideloadly**, **AltStore**, or **SideStore** (using your free Apple ID).

### Option B: Build on a Mac with Xcode
1. Install XcodeGen (`brew install xcodegen`) and run:
   ```bash
   xcodegen generate
   open OTTSubtitleOverlay.xcodeproj
   ```
2. Select your Development Team in **Signing & Capabilities** for both `OTTSubtitleOverlay` and `BroadcastExtension`, connect your iPhone, and press **Run (`Cmd + R`)**.
