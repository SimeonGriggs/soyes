import AppKit
import SwiftUI

@main
struct SoyesApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .defaultSize(width: 760, height: 480)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard PipeModel.shared.hasSession else { return .terminateNow }
        PipeModel.shared.stopForQuit {
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}

struct ContentView: View {
    @ObservedObject private var model = PipeModel.shared

    var body: some View {
        NavigationSplitView {
            List(model.speakers, selection: $model.speakerID) { speaker in
                VStack(alignment: .leading, spacing: 2) {
                    Text(speaker.name)
                    Text(speaker.host)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .tag(speaker.id)
            }
            .navigationTitle("Speakers")
            .navigationSplitViewColumnWidth(min: 200, ideal: 240)
            .disabled(model.isBusy || model.isOn)
        } detail: {
            List(model.apps, selection: $model.appID) { app in
                HStack {
                    Text(app.name)
                    Spacer()
                    if app.outputRunning {
                        Text("Playing")
                            .foregroundStyle(.secondary)
                    }
                }
                .tag(app.id)
            }
            .navigationTitle("Soyes")
            .navigationSubtitle(model.status)
            .disabled(model.isBusy || model.isOn)
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Toggle("Stream", isOn: Binding(
                        get: { model.isOn },
                        set: { model.setStreaming($0) }
                    ))
                    .toggleStyle(.switch)
                    .disabled(model.isBusy || model.selectedSpeaker == nil || model.selectedApp == nil)
                }
                ToolbarItem {
                    Button("Refresh", systemImage: "arrow.clockwise") {
                        model.refresh()
                    }
                    .disabled(model.isBusy || model.isOn)
                }
            }
            .overlay {
                if model.isBusy {
                    ProgressView()
                        .controlSize(.large)
                }
            }
        }
        .onAppear { model.refresh() }
    }
}

@MainActor
final class PipeModel: ObservableObject {
    static let shared = PipeModel()

    @Published var speakers: [FoundSpeaker] = []
    @Published var apps: [AudioApp] = []
    @Published var speakerID: String?
    @Published var appID: pid_t?
    @Published var isOn = false
    @Published var isBusy = false
    @Published var status = "Off"

    private var session: StreamSession?
    var hasSession: Bool { session != nil || isOn }

    var selectedSpeaker: FoundSpeaker? {
        speakers.first { $0.id == speakerID }
    }

    var selectedApp: AudioApp? {
        apps.first { $0.id == appID }
    }

    func refresh() {
        let previousSpeaker = speakerID
        let previousApp = appID
        DispatchQueue.global(qos: .userInitiated).async {
            let speakers = discoverSpeakers()
            let apps = AudioApps.list().filter { !$0.name.hasPrefix("pid ") }
            DispatchQueue.main.async {
                self.speakers = speakers
                self.apps = apps
                if let previousSpeaker, speakers.contains(where: { $0.id == previousSpeaker }) {
                    self.speakerID = previousSpeaker
                } else {
                    self.speakerID = speakers.first { $0.host == "192.168.4.21" || $0.name.caseInsensitiveCompare("Kitchen") == .orderedSame }?.id
                        ?? speakers.first?.id
                }
                if let previousApp, apps.contains(where: { $0.id == previousApp }) {
                    self.appID = previousApp
                } else {
                    self.appID = apps.first { $0.bundleID == "com.apple.Music" || $0.name.caseInsensitiveCompare("Music") == .orderedSame }?.id
                        ?? apps.first { $0.outputRunning }?.id
                        ?? apps.first?.id
                }
            }
        }
    }

    func setStreaming(_ on: Bool) {
        guard !isBusy else { return }
        if !on {
            stop()
            return
        }
        guard let speaker = selectedSpeaker, let app = selectedApp else {
            status = "Choose a speaker and an app."
            isOn = false
            return
        }
        isOn = true
        isBusy = true
        status = "Starting…"
        DispatchQueue.global(qos: .userInitiated).async {
            let session = StreamSession()
            do {
                try session.start(app: app, speaker: speaker)
                DispatchQueue.main.async {
                    self.session = session
                    self.isBusy = false
                    self.status = "Streaming \(app.name) to \(speaker.name)"
                }
            } catch {
                session.stop()
                DispatchQueue.main.async {
                    self.session = nil
                    self.isOn = false
                    self.isBusy = false
                    self.status = error.localizedDescription
                }
            }
        }
    }

    func stop() {
        let session = session
        self.session = nil
        isOn = false
        isBusy = true
        status = "Stopping…"
        DispatchQueue.global(qos: .userInitiated).async {
            session?.stop()
            DispatchQueue.main.async {
                self.isBusy = false
                self.status = "Off"
            }
        }
    }

    func stopForQuit(_ completion: @escaping () -> Void) {
        let session = session
        self.session = nil
        DispatchQueue.global(qos: .userInitiated).async {
            session?.stop()
            DispatchQueue.main.async(execute: completion)
        }
    }
}

final class StreamSession {
    private var capture: Capture?
    private var streamer: Streamer?
    private var speaker: SonosSpeaker?
    private var playback: Playback?
    private var tookOver = false
    private var stopped = false

    func start(app: AudioApp, speaker selected: FoundSpeaker) throws {
        let capture = Capture()
        let streamer = Streamer()
        self.capture = capture
        self.streamer = streamer
        var speaker = SonosSpeaker(host: selected.host)
        speaker.host = speaker.coordinator()
        self.speaker = speaker

        try capture.open(objectIDs: app.objectIDs, mute: true) { samples in
            streamer.write(samples)
        }
        try streamer.start(sampleRate: capture.sampleRate)
        try capture.begin()
        guard streamer.waitForAudio(timeout: 8) else {
            throw PipeError.message("No audio arrived from \(app.name). Start playback in that app, then try again.")
        }
        playback = try speaker.prepare()
        let url = "http://\(localAddress(toward: speaker.host)):\(streamer.port)/stream.mp3"
        try speaker.play(url: url)
        tookOver = true
        Thread.sleep(forTimeInterval: 1.5)
        let state = speaker.transportState()
        if state != "PLAYING" && state != "TRANSITIONING" {
            throw PipeError.message("The speaker did not start the stream (\(state)).")
        }
    }

    func stop() {
        if stopped { return }
        stopped = true
        streamer?.stop()
        capture?.stop()
        if tookOver, let playback, let speaker {
            speaker.restore(playback)
        }
    }
}
