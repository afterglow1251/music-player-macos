# music-player-macos

A modern, Winamp-inspired music player for macOS — built with SwiftUI.

Play local audio, paste a YouTube URL to add a track to your library, and watch
the classic tile spectrum visualizer dance to the music in real time.

![player](docs/screenshot.png)

## Features

- 🎵 **Playback** — MP3 / M4A / WAV / AIFF / FLAC via AVAudioEngine
- 📊 **Real-time visualizer** — Winamp-style spectrum tiles with falling peaks
  (real FFT via Accelerate/vDSP), plus an oscilloscope mode (double-click to switch)
- 📥 **YouTube → MP3** — paste a URL to download & convert into your library
  (with embedded cover art & metadata)
- 🖼️ **Big album artwork** + now-playing info from ID3 tags
- 📃 **Library / playlist** — click to play, hover to delete (moves to Trash)
- ⌨️ **Shortcuts** — Space = play/pause, ⌘←/⌘→ = prev/next, ⌘. = stop
- 🔇 One-click mute, hover effects, custom Dock icon

## Requirements

- macOS 14+
- Xcode 16+ / Swift 6
- For YouTube downloads: [`yt-dlp`](https://github.com/yt-dlp/yt-dlp) and `ffmpeg`

```bash
brew install yt-dlp ffmpeg
```

## Run

```bash
swift run WinampMac
```

Or open `Package.swift` in Xcode and press ▶ (Run).

Downloaded tracks are stored in the `Music/` folder inside the project.

## How the visualizer works

Audio samples are tapped from the output, run through an FFT (Accelerate/vDSP),
grouped into log-spaced frequency bands (bass on the left → treble on the right),
and drawn as stacked colored tiles. Peaks snap up and fall under simulated gravity —
the same feel as the original Winamp.

## License

Personal / educational project. Not affiliated with Winamp or Nullsoft.
