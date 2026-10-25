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
        guard PipeModel.shared.needsCleanup else { return .terminateNow }
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

            LabeledContent("App") {
                HStack(spacing: 4) {
                    Button {
                        model.toggleSourcePlayback()
                    } label: {
                        Image(systemName: model.sourceIsPlaying ? "pause.fill" : "play.fill")
                    }
                    .buttonStyle(.borderless)
                    .frame(width: 22, height: 18)
                    .contentShape(Rectangle())
                    .disabled(model.selectedApp == nil || model.isBusy)
                    .accessibilityLabel(model.sourceIsPlaying ? "Pause" : "Play")
                    .help(model.sourceIsPlaying ? "Pause" : "Play")
                    Picker("App", selection: $model.appID) {
                        ForEach(model.apps) { app in
                            Text(app.name).tag(Optional(app.id))
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .fixedSize()
                    .disabled(model.isBusy || model.isOn)
                }
            }

            LabeledContent("Speaker") {
                HStack(spacing: 8) {
                    if model.selectedSpeaker != nil {
                        Text(model.linkState.title)
                            .foregroundStyle(.secondary)
                            .phaseAnimator(model.linkState.pulses ? [0.35, 1] : [1]) { text, opacity in
                                text.opacity(opacity)
                            } animation: { _ in
                                .easeInOut(duration: 0.75)
                            }
                    }
                    Picker("Speaker", selection: $model.speakerID) {
                        ForEach(model.speakers) { speaker in
                            Text(speaker.name).tag(Optional(speaker.id))
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .fixedSize()
                    .disabled(model.isBusy || model.isOn)
                }
            }

            if !model.nowPlaying.isEmpty {
                LabeledContent("Playing") {
                    Text(model.nowPlaying)
                        .multilineTextAlignment(.trailing)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

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
        .onAppear {
            model.connectSpeaker()
            model.refresh()
            model.refreshSourcePlayback()
        }
        .onReceive(Timer.publish(every: 0.5, on: .main, in: .common).autoconnect()) { _ in
            model.refreshSourcePlayback()
        }
        .onReceive(Timer.publish(every: 1, on: .main, in: .common).autoconnect()) { _ in
            model.loadVolume()
        }
        .onChange(of: model.speakerID) {
            model.loadVolume()
            model.connectSpeaker()
        }
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
    @Published var errorText: String?
    @Published var volume = 20.0
    @Published var sourceIsPlaying = false
    @Published var linkState: LinkState = .searching
    @Published var nowPlaying = ""
    private var volumeLoad = 0
    private var checkingVolume = false
    private var lastSentVolume: Int?
    private var pendingVolume: DispatchWorkItem?
    private var checkingSource = false
    private var toggles = 0

    private var link: SpeakerLink?
    private var session: StreamSession?
    var needsCleanup: Bool { link != nil || session != nil }

    init() {
        let defaults = UserDefaults.standard
        if let host = defaults.string(forKey: "speakerHost") {
            speakers = [FoundSpeaker(name: defaults.string(forKey: "speakerName") ?? host, host: host)]
            speakerID = host
        }
    }

    var selectedSpeaker: FoundSpeaker? {
        speakers.first { $0.id == speakerID }
    }

    var selectedApp: AudioApp? {
        apps.first { $0.id == appID }
    }

    func refresh() {
        let previousApp = appID
        DispatchQueue.global(qos: .userInitiated).async {
            let speakers = discoverSpeakers()
            let apps = AudioApps.list().filter { !$0.name.hasPrefix("pid ") }
            DispatchQueue.main.async {
                let previousSpeaker = self.speakerID
                self.speakers = speakers
                self.apps = apps
                if let previousSpeaker, speakers.contains(where: { $0.id == previousSpeaker }) {
                    self.speakerID = previousSpeaker
                } else {
                    self.speakerID = speakers.first?.id
                }
                self.loadVolume()
                self.refreshSourcePlayback()
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

    func connectSpeaker() {
        guard let speaker = selectedSpeaker, link?.selected.host != speaker.host else { return }
        let previous = link
        let next = SpeakerLink(speaker: speaker)
        next.onState = { [weak self, weak next] state in
            DispatchQueue.main.async {
                guard let self, let next, self.link === next else { return }
                self.linkState = state
            }
        }
        next.onInfo = { [weak self, weak next] info in
            DispatchQueue.main.async {
                guard let self, let next, self.link === next else { return }
                self.nowPlaying = info?.summary ?? ""
            }
        }
        nowPlaying = ""
        next.onError = { [weak self] message in
            DispatchQueue.main.async { self?.errorText = message }
        }
        link = next
        linkState = .searching
        UserDefaults.standard.set(speaker.host, forKey: "speakerHost")
        UserDefaults.standard.set(speaker.name, forKey: "speakerName")
        DispatchQueue.global(qos: .userInitiated).async {
            previous?.close()
        }
        next.open()
    }

    func loadVolume() {
        guard let host = selectedSpeaker?.host, !checkingVolume else { return }
        checkingVolume = true
        volumeLoad += 1
        let request = volumeLoad
        DispatchQueue.global(qos: .userInitiated).async {
            let level = try? SonosSpeaker(host: host).volume()
            DispatchQueue.main.async {
                self.checkingVolume = false
                guard self.speakerID == host else {
                    self.loadVolume()
                    return
                }
                guard self.volumeLoad == request, let level, level != Int(self.volume.rounded()) else { return }
                self.lastSentVolume = level
                self.volume = Double(level)
            }
        }
    }

    func commitVolume() {
        guard let host = selectedSpeaker?.host else { return }
        let level = Int(volume.rounded())
        guard level != lastSentVolume else { return }
        volumeLoad += 1
        lastSentVolume = level
        pendingVolume?.cancel()
        let work = DispatchWorkItem {
            try? SonosSpeaker(host: host).setVolume(level)
        }
        pendingVolume = work
        DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + 0.05, execute: work)
    }

    func refreshSourcePlayback() {
        guard let app = selectedApp else {
            sourceIsPlaying = false
            return
        }
        guard !checkingSource else { return }
        checkingSource = true
        let toggle = toggles
        DispatchQueue.global(qos: .userInitiated).async {
            let playing = SourcePlayback.isPlaying(app)
            DispatchQueue.main.async {
                self.checkingSource = false
                guard self.toggles == toggle, self.appID == app.id else { return }
                self.sourceIsPlaying = playing
            }
        }
    }

    func toggleSourcePlayback() {
        guard let app = selectedApp else { return }
        let playing = sourceIsPlaying
        sourceIsPlaying = !playing
        toggles += 1
        if session != nil {
            if playing {
                link?.pause()
            } else {
                link?.cue()
            }
        }
        SourcePlayback.setPlaying(!playing, app: app)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
            self.refreshSourcePlayback()
        }
    }

    func setStreaming(_ on: Bool) {
        guard !isBusy else { return }
        if !on {
            stop()
            return
        }
        connectSpeaker()
        guard let link, let app = selectedApp else {
            isOn = false
            return
        }
        isOn = true
        isBusy = true
        DispatchQueue.global(qos: .userInitiated).async {
            let session = StreamSession(link: link)
            do {
                try session.start(app: app)
                DispatchQueue.main.async {
                    self.session = session
                    self.isBusy = false
                }
            } catch {
                session.stop()
                DispatchQueue.main.async {
                    self.isOn = false
                    self.isBusy = false
                    self.errorText = error.localizedDescription
                }
            }
        }
    }

    func stop() {
        let session = session
        self.session = nil
        isOn = false
        DispatchQueue.global(qos: .userInitiated).async {
            session?.stop()
        }
    }

    func stopForQuit(_ completion: @escaping () -> Void) {
        let session = session
        let link = link
        self.session = nil
        self.link = nil
        DispatchQueue.global(qos: .userInitiated).async {
            session?.stop()
            link?.close()
            DispatchQueue.main.async(execute: completion)
        }
    }
}
