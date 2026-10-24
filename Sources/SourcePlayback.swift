import AppKit
import Darwin

enum SourcePlayback {
    static func setPlaying(_ playing: Bool, app: AudioApp) {
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

    private static func command(_ verb: String, app: AudioApp) -> String {
        if app.bundleID.isEmpty {
            let name = app.name
                .replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "\"", with: "\\\"")
            return "tell application \"\(name)\" to \(verb)"
        }
        return "tell application id \"\(app.bundleID)\" to \(verb)"
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
