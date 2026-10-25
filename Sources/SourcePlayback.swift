import AppKit
import Darwin

enum SourcePlayback {
    private static let queue = DispatchQueue(label: "soyes.source")
    nonisolated(unsafe) private static var stateScripts: [String: NSAppleScript] = [:]
    nonisolated(unsafe) private static var unsupported: Set<String> = []

    static func setPlaying(_ playing: Bool, app: AudioApp) {
        queue.async {
            send(playing, app: app)
        }
    }

    static func isPlaying(_ app: AudioApp) -> Bool {
        queue.sync { scriptedState(app) } ?? AudioApps.outputRunning(app)
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
