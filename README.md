# Soyes

Soyes sends the audio from one Mac app to a Sonos speaker on your Wi-Fi.

![Soyes](soyes.png)

Choose an app and a speaker, then turn Stream on. Soyes captures that app, mutes it on the Mac, and plays it through the speaker. The speaker stays quiet until the app is actually playing, and it stops as soon as the app goes silent. The play and pause button beside the app name controls that app. The volume slider sets the speaker’s volume.

## Requirements

- macOS 14.4 or later
- A Sonos speaker on the same network
- [ffmpeg](https://ffmpeg.org/), installed with Homebrew (`brew install ffmpeg`)

## Build

```bash
./build.sh
open Soyes.app
```

The first time you turn Stream on, allow Soyes in System Settings → Privacy & Security → Audio Capture.

## How it works

Soyes finds speakers with Bonjour (`_sonos._tcp`) and controls the chosen one over local UPnP on port 1400. It captures the selected app with a Core Audio process tap, encodes that audio to MP3 with ffmpeg, and serves the stream on the local network for the speaker to play. Nothing goes through Sonos cloud or AirPlay.
