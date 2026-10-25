import AppKit
import Darwin

enum SourcePlayback {
    private static let queue = DispatchQueue(label: "soyes.source")
    nonisolated(unsafe) private static var stateScripts: [String: NSAppleScript] = [:]
    nonisolated(unsafe) private static var trackScripts: [String: NSAppleScript] = [:]
    nonisolated(unsafe) private static var unsupported: Set<String> = []
    nonisolated(unsafe) private static var unsupportedTracks: Set<String> = []

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
        return NowPlaying(
            appName: app.name,
            computerName: NowPlaying.thisComputer,
            title: track.0,
            artist: track.1,
            album: track.2
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
