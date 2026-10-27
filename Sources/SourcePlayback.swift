import AppKit
import Darwin

enum SourcePlayback {
    private static let queue = DispatchQueue(label: "soyes.source")
    nonisolated(unsafe) private static var stateScripts: [String: NSAppleScript] = [:]
    nonisolated(unsafe) private static var trackScripts: [String: NSAppleScript] = [:]
    nonisolated(unsafe) private static var artworkScripts: [String: NSAppleScript] = [:]
    nonisolated(unsafe) private static var unsupported: Set<String> = []
    nonisolated(unsafe) private static var unsupportedTracks: Set<String> = []
    nonisolated(unsafe) private static var artworkCache: (key: String, data: Data)?

    static func setPlaying(_ playing: Bool, app: AudioApp) {
        queue.async {
            send(playing, app: app)
        }
    }

    static func isPlaying(_ app: AudioApp) -> Bool {
        queue.sync { scriptedState(app) } ?? AudioApps.outputRunning(app)
    }

    static func nowPlaying(_ app: AudioApp) -> NowPlaying? {
        let track = queue.sync { scriptedTrack(app) }
        guard let track else { return nil }
        let artwork = queue.sync { artwork(for: app, title: track.0, artist: track.1, album: track.2) }
        return NowPlaying(
            appName: app.name,
            computerName: NowPlaying.thisComputer,
            title: track.0,
            artist: track.1,
            album: track.2,
            artwork: artwork
        )
    }

    private static func send(_ playing: Bool, app: AudioApp) {
        let verb = playing ? "play" : "pause"
        var error: NSDictionary?
        NSAppleScript(source: command(verb, app: app))?.executeAndReturnError(&error)
        if error == nil { return }
        let denied = (error?["NSAppleScriptErrorNumber"] as? NSNumber)?.intValue == -1743
        if !denied {
            error = nil
            NSAppleScript(source: command("playpause", app: app))?.executeAndReturnError(&error)
            if error == nil { return }
        }
        MediaCommand.send(playing ? 0 : 1)
    }

    private static func scriptedState(_ app: AudioApp) -> Bool? {
        let key = target(app)
        if unsupported.contains(key) { return nil }
        let script: NSAppleScript
        if let cached = stateScripts[key] {
            script = cached
        } else {
            let source = """
            if \(key) is running then
                with timeout of 2 seconds
                    tell \(key) to return (player state is playing)
                end timeout
            end if
            return false
            """
            var error: NSDictionary?
            guard let compiled = NSAppleScript(source: source), compiled.compileAndReturnError(&error) else {
                unsupported.insert(key)
                return nil
            }
            stateScripts[key] = compiled
            script = compiled
        }
        var error: NSDictionary?
        let result = script.executeAndReturnError(&error)
        if let error {
            if (error["NSAppleScriptErrorNumber"] as? NSNumber)?.intValue != -1712 {
                unsupported.insert(key)
            }
            return nil
        }
        return result.booleanValue
    }

    private static func scriptedTrack(_ app: AudioApp) -> (String, String, String)? {
        let key = target(app)
        if unsupportedTracks.contains(key) { return ("", "", "") }
        let script: NSAppleScript
        if let cached = trackScripts[key] {
            script = cached
        } else {
            let source = """
            on clean(value)
                if value is missing value then return ""
                return value
            end clean
            if \(key) is running then
                with timeout of 1 second
                    tell \(key)
                        try
                            set t to current track
                            set trackName to ""
                            set trackArtist to ""
                            set trackAlbum to ""
                            try
                                set trackName to my clean(name of t as string)
                            end try
                            try
                                set trackArtist to my clean(artist of t as string)
                            end try
                            try
                                set trackAlbum to my clean(album of t as string)
                            end try
                            return trackName & linefeed & trackArtist & linefeed & trackAlbum
                        end try
                    end tell
                end timeout
            end if
            return ""
            """
            var error: NSDictionary?
            guard let compiled = NSAppleScript(source: source), compiled.compileAndReturnError(&error) else {
                unsupportedTracks.insert(key)
                return ("", "", "")
            }
            trackScripts[key] = compiled
            script = compiled
        }
        var error: NSDictionary?
        let result = script.executeAndReturnError(&error)
        if let error {
            if (error["NSAppleScriptErrorNumber"] as? NSNumber)?.intValue == -1712 { return nil }
            return ("", "", "")
        }
        let lines = result.stringValue?.components(separatedBy: "\n") ?? []
        func line(_ index: Int) -> String {
            guard lines.indices.contains(index) else { return "" }
            return lines[index]
        }
        return (line(0), line(1), line(2))
    }

    private static func artwork(for app: AudioApp, title: String, artist: String, album: String) -> Data {
        guard !title.isEmpty || !artist.isEmpty else { return Data() }
        let key = "\(target(app))\n\(title)\n\(artist)\n\(album)"
        if let artworkCache, artworkCache.key == key { return artworkCache.data }
        guard let data = fetchedArtwork(for: app) else { return Data() }
        artworkCache = (key, data)
        return data
    }

    private static func fetchedArtwork(for app: AudioApp) -> Data? {
        if app.bundleID == "com.apple.Music" || app.name.caseInsensitiveCompare("Music") == .orderedSame {
            return musicArtwork(app)
        }
        if app.bundleID == "com.spotify.client" {
            return spotifyArtwork(app)
        }
        return Data()
    }

    /// Spotify only exposes a cover URL, so the image is downloaded once per track.
    private static func spotifyArtwork(_ app: AudioApp) -> Data? {
        let key = target(app)
        let script: NSAppleScript
        if let cached = artworkScripts[key] {
            script = cached
        } else {
            let source = """
            if \(key) is running then
                with timeout of 2 seconds
                    tell \(key)
                        try
                            return artwork url of current track
                        end try
                    end tell
                end timeout
            end if
            return ""
            """
            var error: NSDictionary?
            guard let compiled = NSAppleScript(source: source), compiled.compileAndReturnError(&error) else {
                return Data()
            }
            artworkScripts[key] = compiled
            script = compiled
        }
        var error: NSDictionary?
        let result = script.executeAndReturnError(&error)
        if let error {
            if (error["NSAppleScriptErrorNumber"] as? NSNumber)?.intValue == -1712 { return nil }
            return Data()
        }
        guard let text = result.stringValue, let url = URL(string: text), url.scheme == "https" else { return Data() }
        var request = URLRequest(url: url)
        request.timeoutInterval = 3
        var body: Data?
        let done = DispatchSemaphore(value: 0)
        URLSession.shared.dataTask(with: request) { data, response, _ in
            if let data, let response = response as? HTTPURLResponse, (200..<300).contains(response.statusCode) {
                body = data
            }
            done.signal()
        }.resume()
        _ = done.wait(timeout: .now() + 3.5)
        // nil is not cached, so a failed download is retried on the next poll.
        guard let body else { return nil }
        return imageData(body) ?? Data()
    }

    private static func musicArtwork(_ app: AudioApp) -> Data? {
        let key = target(app)
        let script: NSAppleScript
        if let cached = artworkScripts[key] {
            script = cached
        } else {
            let source = """
            if \(key) is running then
                with timeout of 2 seconds
                    tell \(key)
                        try
                            if (count of artworks of current track) is 0 then return ""
                            return raw data of artwork 1 of current track
                        end try
                    end tell
                end timeout
            end if
            return ""
            """
            var error: NSDictionary?
            guard let compiled = NSAppleScript(source: source), compiled.compileAndReturnError(&error) else {
                return Data()
            }
            artworkScripts[key] = compiled
            script = compiled
        }
        var error: NSDictionary?
        let result = script.executeAndReturnError(&error)
        if let error {
            if (error["NSAppleScriptErrorNumber"] as? NSNumber)?.intValue == -1712 { return nil }
            return Data()
        }
        if let image = imageData(result.data) { return image }
        if let coerced = result.coerce(toDescriptorType: typeData), let image = imageData(coerced.data) {
            return image
        }
        return Data()
    }

    private static func imageData(_ data: Data) -> Data? {
        guard data.count > 32, let image = NSImage(data: data), image.size.width > 1, image.size.height > 1 else {
            return nil
        }
        return data
    }

    private static func target(_ app: AudioApp) -> String {
        if app.bundleID.isEmpty {
            let name = app.name
                .replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "\"", with: "\\\"")
            return "application \"\(name)\""
        }
        return "application id \"\(app.bundleID)\""
    }

    private static func command(_ verb: String, app: AudioApp) -> String {
        "tell \(target(app)) to \(verb)"
    }
}

private enum MediaCommand {
    static func send(_ command: UInt32) {
        guard let handle = dlopen("/System/Library/PrivateFrameworks/MediaRemote.framework/MediaRemote", RTLD_NOW),
              let symbol = dlsym(handle, "MRMediaRemoteSendCommand") else { return }
        let send = unsafeBitCast(symbol, to: (@convention(c) (UInt32, CFDictionary?) -> Void).self)
        send(command, nil)
    }
}
