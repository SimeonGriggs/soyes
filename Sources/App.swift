import AppKit
import SwiftUI

@main
struct SoyesApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .defaultSize(width: 420, height: 320)
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
        Form {
            Toggle("Stream", isOn: Binding(
                get: { model.isOn },
                set: { model.setStreaming($0) }
            ))
            .toggleStyle(.switch)
            .disabled(model.isBusy || model.selectedSpeaker == nil || model.selectedApp == nil)

            Picker("App", selection: $model.appID) {
                ForEach(model.apps) { app in
                    Text(app.name).tag(Optional(app.id))
                }
            }
            .pickerStyle(.menu)
            .disabled(model.isBusy || model.isOn)

            Picker("Speaker", selection: $model.speakerID) {
                ForEach(model.speakers) { speaker in
                    Text(speaker.name).tag(Optional(speaker.id))
                }
            }
            .pickerStyle(.menu)
            .disabled(model.isBusy || model.isOn)

            Slider(value: $model.volume, in: 0...100) {
                Text("Volume")
            } onEditingChanged: { _ in
                model.commitVolume()
            }
            .disabled(model.selectedSpeaker == nil || model.isBusy)
            .onChange(of: model.volume) { model.commitVolume() }
        }
        .formStyle(.grouped)
        .frame(minWidth: 380, minHeight: 220)
        .onAppear { model.refresh() }
        .onChange(of: model.speakerID) { model.loadVolume() }
        .alert("Soyes", isPresented: Binding(
            get: { model.errorText != nil },
            set: { if !$0 { model.errorText = nil } }
        )) {
            Button("OK") { model.errorText = nil }
        } message: {
            Text(model.errorText ?? "")
        }
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
    @Published var errorText: String?
    @Published var volume = 20.0
    private var volumeLoad = 0
    private var lastSentVolume: Int?
    private var pendingVolume: DispatchWorkItem?

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
                    self.speakerID = speakers.first?.id
                }
                self.loadVolume()
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

    func loadVolume() {
        guard let host = selectedSpeaker?.host else { return }
        volumeLoad += 1
        let request = volumeLoad
        DispatchQueue.global(qos: .userInitiated).async {
            let level = try? SonosSpeaker(host: host).volume()
            DispatchQueue.main.async {
                guard self.volumeLoad == request, let level else { return }
                self.lastSentVolume = level
                self.volume = Double(level)
            }
        }
    }

    func commitVolume() {
        guard let host = selectedSpeaker?.host else { return }
        let level = Int(volume.rounded())
        guard level != lastSentVolume else { return }
        lastSentVolume = level
        pendingVolume?.cancel()
        let work = DispatchWorkItem {
            try? SonosSpeaker(host: host).setVolume(level)
        }
        pendingVolume = work
        DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + 0.05, execute: work)
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
            session.onStatus = { text in
                DispatchQueue.main.async {
                    guard self.isOn else { return }
                    self.status = text
                }
            }
            do {
                try session.start(app: app, speaker: speaker)
                DispatchQueue.main.async {
                    self.session = session
                    self.isBusy = false
                    self.status = "Listening to \(app.name)"
                }
            } catch {
                session.stop()
                DispatchQueue.main.async {
                    self.session = nil
                    self.isOn = false
                    self.isBusy = false
                    self.status = "Off"
                    self.errorText = error.localizedDescription
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
    private var streamURL: String?
    private var tookOver = false
    private var stopped = false
    private var engaging = false
    private var speakerHolding = false
    private var lastSound = Date()
    private let lock = NSLock()
    private let control = NSLock()
    private var appName = ""
    private var speakerName = ""
    var onStatus: ((String) -> Void)?

    func start(app: AudioApp, speaker selected: FoundSpeaker) throws {
        appName = app.name
        speakerName = selected.name
        let capture = Capture()
        let streamer = Streamer()
        self.capture = capture
        self.streamer = streamer
        var speaker = SonosSpeaker(host: selected.host)
        speaker.host = speaker.coordinator()
        self.speaker = speaker
        Thread.detachNewThread { [weak self] in
            self?.watchSilence()
        }

        try capture.open(objectIDs: app.objectIDs, mute: true) { [weak self] samples in
            self?.noteLevel(samples)
            streamer.write(samples)
        }
        try streamer.start(sampleRate: capture.sampleRate)
        try capture.begin()
        streamURL = "http://\(localAddress(toward: speaker.host)):\(streamer.port)/stream.mp3"
    }

    func stop() {
        lock.lock()
        if stopped {
            lock.unlock()
            return
        }
        stopped = true
        lock.unlock()
        streamer?.stop()
        capture?.stop()
        control.lock()
        if tookOver, let playback, let speaker {
            speaker.restore(playback)
        }
        control.unlock()
    }

    private func noteLevel(_ samples: [Int16]) {
        var peak = 0
        var index = 0
        while index < samples.count {
            let value = Int(samples[index])
            peak = max(peak, value < 0 ? -value : value)
            index += 64
        }
        guard peak > 400 else { return }
        lock.lock()
        lastSound = Date()
        let shouldStart = !tookOver && !engaging && !stopped
        if shouldStart { engaging = true }
        let shouldResume = speakerHolding && tookOver && !stopped
        if shouldResume { speakerHolding = false }
        lock.unlock()
        if shouldStart {
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                self?.beginPlayback()
            }
        } else if shouldResume {
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                self?.resumePlayback()
            }
        }
    }

    private func beginPlayback() {
        control.lock()
        defer { control.unlock() }
        guard !stopped, let speaker, let streamer, let url = streamURL else {
            lock.lock()
            engaging = false
            lock.unlock()
            return
        }
        do {
            if playback == nil {
                playback = try speaker.prepare()
            }
            if streamer.mp3Bytes == 0 {
                _ = streamer.waitForAudio(timeout: 3)
            }
            lock.lock()
            let cancelled = stopped
            lock.unlock()
            guard !cancelled else { return }
            try speaker.play(url: url)
            lock.lock()
            tookOver = true
            engaging = false
            speakerHolding = false
            lastSound = Date()
            lock.unlock()
            onStatus?("Streaming \(appName) to \(speakerName)")
        } catch {
            lock.lock()
            engaging = false
            lock.unlock()
        }
    }

    private func resumePlayback() {
        control.lock()
        defer { control.unlock() }
        guard !stopped, let speaker, let url = streamURL else { return }
        try? speaker.play(url: url)
        onStatus?("Streaming \(appName) to \(speakerName)")
    }

    private func watchSilence() {
        while true {
            Thread.sleep(forTimeInterval: 0.05)
            lock.lock()
            if stopped {
                lock.unlock()
                return
            }
            let quiet = tookOver && Date().timeIntervalSince(lastSound) > 0.25
            let shouldStop = quiet && !speakerHolding
            if shouldStop { speakerHolding = true }
            let speaker = speaker
            let streamer = streamer
            lock.unlock()
            guard shouldStop, let speaker, let streamer else { continue }
            control.lock()
            lock.lock()
            let stillHolding = !stopped && speakerHolding
            lock.unlock()
            if stillHolding {
                streamer.cut()
                try? speaker.stopPlayback()
                onStatus?("Listening to \(appName)")
            }
            control.unlock()
        }
    }
}
