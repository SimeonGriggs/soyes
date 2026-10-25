# Soyes

Soyes sends the audio from one Mac app to a Sonos speaker on your Wi-Fi.

![Soyes](soyes.png)

Choose an app and a speaker, then turn Stream on. Soyes captures that app, mutes it on the Mac, and plays it through the speaker, about half a second behind. The speaker chimes when Stream connects it, and its status light blinks while it connects or while audio is on its way after you press play. The speaker mutes the moment the app pauses. The play and pause button beside the app name controls that app. The volume slider sets the speaker’s volume.

## Requirements

- macOS 14.4 or later
- A Sonos speaker on the same network

## Build

```bash
./build.sh
open Soyes.app
```

The first time you turn Stream on, allow Soyes in System Settings → Privacy & Security → Audio Capture.

## How it works

Soyes finds speakers with Bonjour (`_sonos._tcp`) and controls the chosen one over local UPnP on port 1400. It captures the selected app with a Core Audio process tap and serves that audio as an uncompressed WAV stream on the local network for the speaker to play. Nothing goes through Sonos cloud or AirPlay.

Sonos waits for a fixed amount of data before it starts a stream, so compressed formats take seconds to start while uncompressed WAV starts in about half a second. Soyes connects as soon as it opens, as long as the speaker isn’t playing something else, and keeps the stream open with silence until there’s audio to send, so the speaker never has to reconnect. The status beside the speaker shows whether Soyes is connected, still connecting, or the speaker is in use. Quitting puts the speaker back the way it was.

`scripts/probe-formats.py` measures how quickly a speaker starts each stream format. It needs [ffmpeg](https://ffmpeg.org/) (`brew install ffmpeg`). Quit Soyes, then run it from Terminal with `python3 scripts/probe-formats.py`.
