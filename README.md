# CameraShot

A native macOS assistant that watches your camera or screen, listens to audio, and streams AI answers into a floating window that stays hidden from screen sharing.

Built in Swift with AppKit, AVFoundation, and ScreenCaptureKit. It has no package dependencies.

## Features

- **Interval capture.** Grabs a frame from any camera (including Continuity Camera), a display, or a single window every *N* seconds. A change filter skips frames that look the same as the last one.
- **Visual AI.** Sends each new frame with your own prompt to Google Gemini (default `gemini-3.8-flash`) or OpenAI (`gpt-6.1-terra`). The answer streams in as Markdown, with code highlighting and Mermaid diagrams.
- **Realtime audio.** Connects to the OpenAI Realtime API (`gpt-realtime-2.1`) over WebSocket and offers three modes:
  - *Audio AI*: listens all the time and answers system audio as it plays.
  - *Instant Voice* and *Instant Audio2*: push-to-talk, each with its own prompt.
- **Chat.** A `gpt-6.1-sol` text chat that can use the latest screenshot as context.
- **Codex tab.** Runs the [OpenAI Codex CLI](https://github.com/openai/codex) inside the app, if you have it installed.
- **Hidden from screen sharing.** Every window sets `NSWindow.sharingType = .none`, so it doesn't appear in Zoom, Meet, Teams, or screen recordings.
- **Encrypted keys.** API keys are encrypted with AES-256-GCM, using a key derived with PBKDF2 from this Mac's hardware UUID, and stored in `~/.camerashot/`. They never appear in plain text on disk.
- **Bounded memory.** Old screenshots and rendered entries are removed automatically, so the app can run for hours (see `RetentionPolicy.swift`).

## Requirements

- macOS 14 Sonoma or later
- Xcode Command Line Tools (`xcode-select --install`)
- A Google Gemini and/or OpenAI API key
- Optional: the `codex` CLI on your `PATH` for the Codex tab

## Build and run

```bash
git clone https://github.com/zeinalii/CameraShot.git
cd CameraShot

make build          # builds and signs CameraShot.app
./run.sh            # opens the app (builds it first if needed)
./run.sh --build    # rebuilds, then opens the app
make dev            # debug build that prints logs to the terminal
make install        # copies the app to /Applications
```

`make build` signs the app with the first **Developer ID Application** identity in your keychain. If you don't have one, it falls back to ad-hoc signing. To choose an identity yourself, pass `SIGN_IDENTITY="Developer ID Application: …"`.

The first time it runs, macOS asks for camera, microphone, and screen-recording permission. CameraShot is a menu-bar app (`LSUIElement`), so it doesn't show a Dock icon.

## Usage

1. Open **Settings → API Keys** and paste your Gemini and/or OpenAI key. Keys are encrypted as soon as you save them.
2. On the **Capture** tab, choose a camera or a screen/window source, an interval, an image quality, and an output folder. Then turn on the AI tabs you want.
3. Write your visual and audio prompts on the **Prompts** and **Audio Prompts** tabs. They start empty, so the AI only gets the image or audio until you add your own instructions.
4. Click **Start Capture**. Answers appear in the floating capture window, one tab per mode.

Frames are saved to `~/Documents/CameraShot/` by default. Only the 30 most recent frames are kept.

## Project layout

| File | Purpose |
|---|---|
| `AppDelegate.swift` | App lifecycle, permissions, and wiring between the controllers |
| `SetupWindowController.swift` | Settings window (capture source, prompts, API keys) |
| `CaptureWindowController.swift` | Floating results window and its WebView tabs |
| `CameraController.swift` / `ScreenCaptureController.swift` | Frame capture |
| `FrameChangeFilter.swift` | Skips near-duplicate frames |
| `AIProcessor.swift` | Gemini and OpenAI vision requests |
| `RealtimeAudioAIController.swift` | OpenAI Realtime WebSocket audio |
| `GPTChatController.swift` | Text chat |
| `EncryptedKeyStore.swift` / `PassphraseManager.swift` | Encrypted API key storage |

Rendering uses bundled copies of [marked](https://github.com/markedjs/marked), [highlight.js](https://github.com/highlightjs/highlight.js), and [Mermaid](https://github.com/mermaid-js/mermaid), found in `Sources/CameraShot/Resources/`.

## Privacy

- Captured frames and audio go only to the AI provider you configure. They are sent directly from your Mac, with no relay server in between.
- The key encryption is tied to this specific Mac. It stops someone from reading your keys from a copied file. It does **not** protect them from another process running as your user, because the derivation formula is visible in the source.

## Disclaimer

The hide-from-screen-sharing feature makes this tool easy to misuse. Use it only where you are allowed to: respect the rules of interviews, exams, meetings, and recordings, and the laws that apply to you.
