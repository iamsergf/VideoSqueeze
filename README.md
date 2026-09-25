# VideoSqueeze

**English** · [Русский](README.ru.md)

A tiny native macOS app for compressing videos. Drop files in, press **Compress**, get smaller MP4s next to the originals.

It uses Apple's hardware video encoder (VideoToolbox), so on Apple Silicon a minute of 1080p video compresses in a few seconds without spinning up the fans.

## Features

- **Drag & drop** one or many videos (MOV, MP4, M4V and anything else macOS can play)
- **Two modes**
  - **By quality** — pick High / Medium / Low and a maximum resolution
  - **By size** — "no bigger than N MB" (e.g. 5 MB for messengers or email). The app picks the bitrate, resolution and, if needed, frame rate, then checks the result and re-encodes if it overshot
- **HEVC (H.265)** or **H.264**
- Keeps rotation of phone videos and HDR (10-bit HEVC) from iPhone
- Never increases the bitrate above the original
- Universal app: Apple Silicon and Intel, ~1 MB

## Download

1. Grab **VideoSqueeze.zip** from the [latest release](../../releases/latest).
2. Unzip it and move **VideoSqueeze.app** to **Applications**.
3. The first launch will be blocked, because the app is not notarized by Apple (that requires a paid developer account). To allow it:
   - Try to open the app once, then go to **System Settings → Privacy & Security**, scroll down and click **Open Anyway**.
   - Or run this in Terminal:
     ```bash
     xattr -dr com.apple.quarantine /Applications/VideoSqueeze.app
     ```

Requires **macOS 14 Sonoma** or newer.

## How much fits into N MB?

File size ≈ bitrate × duration, so the longer the video, the lower the quality at a fixed size. Rough guide for a 5 MB limit:

| Video length | Available bitrate | What you get |
|---|---|---|
| 30 sec | ~1.3 Mbit/s | good 720p–1080p |
| 2 min | ~330 kbit/s | decent 360p–480p |
| 10 min | ~65 kbit/s | 144p, reduced frame rate — only for sending |

## Build from source

You need Xcode (or the Xcode Command Line Tools with the macOS SDK).

```bash
git clone https://github.com/iamsergf/VideoSqueeze.git
cd VideoSqueeze
./build.sh
```

The app is written to `build/VideoSqueeze.app`, and a zip for releases to `build/VideoSqueeze.zip`.

There's also a headless mode for scripting:

```bash
build/VideoSqueeze.app/Contents/MacOS/VideoSqueeze --cli input.mov output.mp4 size=5
```

Options: `size=<MB>` (target-size mode), `h264`, `720` (limit to 720p).

## Project layout

| File | What's inside |
|---|---|
| `Sources/Compressor.swift` | Compression engine (AVFoundation: AVAssetReader → AVAssetWriter) |
| `Sources/AppModel.swift` | File queue and state |
| `Sources/ContentView.swift` | SwiftUI interface |
| `Sources/main.swift` | Entry point and CLI mode |
| `build.sh` | Builds the universal .app and the release zip |
| `make_icon.swift` | Draws the app icon |

## License

[MIT](LICENSE)
