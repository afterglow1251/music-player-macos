# Sonar

A modern, retro-inspired music player for macOS — built with SwiftUI.

Play local audio, paste a YouTube URL to add a track to your library, and watch
the tile spectrum visualizer dance to the music in real time.

![player](docs/screenshot.png)

## Features

- 🎵 **Playback** — MP3 / M4A / WAV / AIFF / FLAC via AVAudioEngine
- 📊 **Real-time visualizer** — spectrum tiles with falling peaks (real FFT via
  Accelerate/vDSP), plus an oscilloscope mode (double-click to switch), 10 color themes
- 📥 **YouTube → MP3** — paste a URL to download & convert into your library
  (with embedded cover art & metadata)
- 🎚️ **10-band equalizer** with presets
- 🖼️ **Big album artwork** (that breathes to the bass) + ID3 metadata
- 📃 **Library / playlist** — search, click to play, hover to delete, resume where you left off
- ⌨️ **Shortcuts & media keys** — Space, ⌘←/⌘→, ⌥←/⌥→, and Now Playing in Control Center
- 🔀 Shuffle / repeat, 😴 sleep timer, and a custom Dock icon

## Requirements

- macOS 14+
- Xcode 16+ / Swift 6
- For YouTube downloads: [`yt-dlp`](https://github.com/yt-dlp/yt-dlp) and `ffmpeg`

```bash
brew install yt-dlp ffmpeg
```

## Run

```bash
swift run Sonar
```

Or open `Package.swift` in Xcode and press ▶ (Run).

Downloaded tracks are stored in **`~/Documents/Sonar/`** (reachable from Finder).

## How the visualizer works

Audio samples are tapped from the output, run through an FFT (Accelerate/vDSP),
grouped into log-spaced frequency bands (bass on the left → treble on the right),
and drawn as stacked colored tiles. Peaks snap up and fall under simulated gravity.

## License

Personal / educational project.
