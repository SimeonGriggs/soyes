import AppKit
import SwiftUI

@main
struct SoyesApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup(id: "main") {
            ContentView()
        }
        .defaultSize(width: 420, height: 520)

        MenuBarExtra {
            MenuBarView()
        } label: {
            MenuBarLabel()
        }
        .menuBarExtraStyle(.window)
    }
}

private struct MenuBarLabel: View {
    @ObservedObject private var model = PipeModel.shared

    var body: some View {
        Image(systemName: model.menuIcon)
            .accessibilityLabel(model.isOn ? "Soyes, streaming" : "Soyes")
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        DispatchQueue.global(qos: .userInitiated).async {
            Capture.requestAccess()
        }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard PipeModel.shared.needsCleanup else { return .terminateNow }
        PipeModel.shared.stopForQuit {
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}

/// Polls the source app's play state and the speaker volume while a view is visible.
private struct ModelPolling: ViewModifier {
    @ObservedObject var model: PipeModel

    func body(content: Content) -> some View {
        content
            .onReceive(Timer.publish(every: 0.5, on: .main, in: .common).autoconnect()) { _ in
                model.refreshSourcePlayback()
            }
            .onReceive(Timer.publish(every: 1, on: .main, in: .common).autoconnect()) { _ in
                model.loadVolume()
            }
    }
}

// MARK: - Menu bar panel

/// A Control Center–style panel: a header with the main switch, then the source,
/// the speakers as a multi-select list, volume, and footer commands.
struct MenuBarView: View {
    @ObservedObject private var model = PipeModel.shared
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding(.horizontal, 14)
                .padding(.top, 12)
                .padding(.bottom, 10)

            section("Now Playing") {
                HStack(spacing: 10) {
                    Group {
                        if let artwork = model.artwork {
                            Image(nsImage: artwork)
                                .resizable()
                                .interpolation(.high)
                                .aspectRatio(contentMode: .fill)
                        } else {
                            Image(systemName: "music.note")
                                .font(.system(size: 18))
                                .foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                                .background(.quaternary)
                        }
                    }
                    .frame(width: 48, height: 48)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .accessibilityHidden(true)

                    VStack(alignment: .leading, spacing: 1) {
                        Text(nowPlayingTitle)
                            .font(.body.weight(.semibold))
                            .lineLimit(2)
                        if !model.trackArtist.isEmpty {
                            Text(model.trackArtist)
                                .font(.callout)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                    .help(trackLine)

                    Spacer(minLength: 4)

                    Button {
                        model.toggleSourcePlayback()
                    } label: {
                        Image(systemName: model.sourceIsPlaying ? "pause.fill" : "play.fill")
                            .font(.system(size: 13))
                            .frame(width: 30, height: 30)
                            .background(Circle().fill(.quaternary))
                            .contentShape(Circle())
                    }
                    .buttonStyle(.plain)
                    .disabled(model.selectedApp == nil)
                    .accessibilityLabel(model.sourceIsPlaying ? "Pause" : "Play")
                    .help(model.sourceIsPlaying ? "Pause" : "Play")
                }
                .padding(.horizontal, 8)
                .padding(.bottom, 6)

                Picker("App", selection: Binding(
                    get: { model.appID },
                    set: { model.setApp($0) }
                )) {
                    if model.apps.isEmpty {
                        Text("No Apps Playing Audio").tag(pid_t?.none)
                    }
                    ForEach(model.apps) { app in
                        Text(app.name).tag(Optional(app.id))
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .frame(maxWidth: .infinity)
                .padding(.horizontal, 8)
            }

            section("Speakers") {
                if model.speakers.isEmpty {
                    Text(model.isDiscovering ? "Looking for speakers…" : "No speakers found")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                }
                ForEach(model.speakers) { speaker in
                    SpeakerRow(
                        name: speaker.name,
                        isSelected: model.selectedIDs.contains(speaker.id)
                    ) {
                        model.toggleSpeaker(speaker.id)
                    }
                }
            }

            HStack(spacing: 8) {
                Image(systemName: "speaker.fill")
                Slider(value: $model.volume, in: 0...100) {
                    Text("Volume")
                } onEditingChanged: { _ in
                    model.commitVolume()
                }
                .labelsHidden()
                .onChange(of: model.volume) { model.commitVolume() }
                Image(systemName: "speaker.wave.3.fill")
            }
            .foregroundStyle(.secondary)
            .disabled(model.selectedIDs.isEmpty)
            .padding(.horizontal, 14)
            .padding(.vertical, 10)

            Divider().padding(.horizontal, 14)

            VStack(spacing: 0) {
                HStack {
                    Text("Format")
                    Spacer()
                    Picker("Format", selection: Binding(
                        get: { model.streamFormat },
                        set: { model.setStreamFormat($0) }
                    )) {
                        ForEach(StreamFormat.allCases) { format in
                            Text(format.title).tag(format)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .fixedSize()
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 2)

                Button("Open Soyes Window") {
                    openWindow(id: "main")
                    NSApp.activate()
                }
                .buttonStyle(PanelRowStyle())

                Button {
                    NSApp.terminate(nil)
                } label: {
                    HStack {
                        Text("Quit Soyes")
                        Spacer()
                        Text("⌘Q").foregroundStyle(.secondary)
                    }
                }
                .buttonStyle(PanelRowStyle())
                .keyboardShortcut("q")
            }
            .padding(6)
        }
        .frame(width: 300)
        .modifier(ModelPolling(model: model))
        .onAppear {
            model.refresh()
        }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Soyes")
                    .font(.headline)
                Text(model.errorText ?? model.statusText)
                    .font(.caption)
                    .foregroundStyle(model.errorText == nil ? AnyShapeStyle(.secondary) : AnyShapeStyle(.red))
                    .lineLimit(2)
                    .onTapGesture { model.errorText = nil }
            }
            Spacer(minLength: 8)
            Toggle("Stream", isOn: Binding(
                get: { model.isOn },
                set: { model.setStreaming($0) }
            ))
            .labelsHidden()
            .toggleStyle(.switch)
            .disabled(!model.canStream)
            .accessibilityLabel("Stream")
        }
    }

    private var trackLine: String {
        [model.trackTitle, model.trackArtist, model.trackAlbum].filter { !$0.isEmpty }.joined(separator: " — ")
    }

    private var nowPlayingTitle: String {
        if !model.trackTitle.isEmpty { return model.trackTitle }
        return model.selectedApp?.name ?? "Nothing playing"
    }

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 8)
                .padding(.bottom, 2)
            content()
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 6)
    }
}

private struct SpeakerRow: View {
    let name: String
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: "hifispeaker.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(isSelected ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
                    .frame(width: 26, height: 26)
                    .background(Circle().fill(isSelected ? AnyShapeStyle(.tint) : AnyShapeStyle(.quaternary)))
                Text(name)
                    .lineLimit(1)
                Spacer()
                if isSelected {
                    Image(systemName: "checkmark")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
            }
        }
        .buttonStyle(PanelRowStyle(vertical: 3))
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

/// A full-width row that highlights on hover, like the rows in Control Center.
private struct PanelRowStyle: ButtonStyle {
    var vertical: CGFloat = 5

    func makeBody(configuration: Configuration) -> some View {
        Row(configuration: configuration, vertical: vertical)
    }

    private struct Row: View {
        let configuration: ButtonStyleConfiguration
        let vertical: CGFloat
        @State private var hovering = false
        @Environment(\.isEnabled) private var isEnabled

        var body: some View {
            configuration.label
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 8)
                .padding(.vertical, vertical)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(.quaternary)
                        .opacity(isEnabled && (hovering || configuration.isPressed) ? 1 : 0)
                )
                .contentShape(Rectangle())
                .opacity(isEnabled ? 1 : 0.5)
                .onHover { hovering = $0 }
        }
    }
}

// MARK: - Window

struct ContentView: View {
    @ObservedObject private var model = PipeModel.shared

    var body: some View {
        Form {
            Section {
                LabeledContent("Stream") {
                    HStack(spacing: 10) {
                        Text(model.statusText)
                            .foregroundStyle(.secondary)
                            .phaseAnimator(model.isOn && model.linkState.pulses ? [0.35, 1] : [1]) { text, opacity in
                                text.opacity(opacity)
                            } animation: { _ in
                                .easeInOut(duration: 0.75)
                            }
                        Picker("Format", selection: Binding(
                            get: { model.streamFormat },
                            set: { model.setStreamFormat($0) }
                        )) {
                            ForEach(StreamFormat.allCases) { format in
                                Text(format.title).tag(format)
                            }
                        }
                        .labelsHidden()
                        .pickerStyle(.menu)
                        .fixedSize()
                        Toggle("Stream", isOn: Binding(
                            get: { model.isOn },
                            set: { model.setStreaming($0) }
                        ))
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .accessibilityLabel("Stream")
                        .disabled(!model.canStream)
                    }
                }

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
                        .disabled(model.selectedApp == nil)
                        .accessibilityLabel(model.sourceIsPlaying ? "Pause" : "Play")
                        .help(model.sourceIsPlaying ? "Pause" : "Play")
                        Picker("App", selection: Binding(
                            get: { model.appID },
                            set: { model.setApp($0) }
                        )) {
                            if model.apps.isEmpty {
                                Text("No Apps Playing Audio").tag(pid_t?.none)
                            }
                            ForEach(model.apps) { app in
                                Text(app.name).tag(Optional(app.id))
                            }
                        }
                        .labelsHidden()
                        .pickerStyle(.menu)
                        .fixedSize()
                    }
                }

                Slider(value: $model.volume, in: 0...100) {
                    Text("Volume")
                } onEditingChanged: { _ in
                    model.commitVolume()
                }
                .disabled(model.selectedIDs.isEmpty)
                .onChange(of: model.volume) { model.commitVolume() }
            }

            Section("Speakers") {
                if model.speakers.isEmpty {
                    Text(model.isDiscovering ? "Looking for speakers…" : "No speakers found")
                        .foregroundStyle(.secondary)
                }
                ForEach(model.speakers) { speaker in
                    Toggle(speaker.name, isOn: Binding(
                        get: { model.selectedIDs.contains(speaker.id) },
                        set: { _ in model.toggleSpeaker(speaker.id) }
                    ))
                    .toggleStyle(.checkbox)
                }
            }

            if !model.trackTitle.isEmpty || model.artwork != nil {
                Section("Playing") {
                    HStack(alignment: .center, spacing: 10) {
                        if let artwork = model.artwork {
                            Image(nsImage: artwork)
                                .resizable()
                                .interpolation(.high)
                                .aspectRatio(contentMode: .fill)
                                .frame(width: 54, height: 54)
                                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                                .accessibilityLabel("Cover")
                        }
                        VStack(alignment: .leading, spacing: 2) {
                            Text(model.trackTitle)
                                .fontWeight(.bold)
                                .lineLimit(2)
                            if !trackDetail.isEmpty {
                                Text(trackDetail)
                                    .lineLimit(2)
                            }
                            if !model.trackSource.isEmpty {
                                Text(model.trackSource)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .frame(minWidth: 380, minHeight: 340)
        .modifier(ModelPolling(model: model))
        .onAppear {
            model.refresh()
            model.refreshSourcePlayback()
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

    private var trackDetail: String {
        [model.trackArtist, model.trackAlbum].filter { !$0.isEmpty }.joined(separator: " • ")
    }
}

// MARK: - Model

@MainActor
final class PipeModel: ObservableObject {
    static let shared = PipeModel()

    @Published var speakers: [FoundSpeaker] = []
    @Published var apps: [AudioApp] = []
    @Published var selectedIDs: Set<String> = []
    @Published var appID: pid_t?
    @Published var isOn = false
    @Published var streamFormat: StreamFormat = .wav
    @Published var isBusy = false
    @Published var isDiscovering = false
    @Published var errorText: String?
    @Published var volume = 20.0
    @Published var sourceIsPlaying = false
    @Published var linkState: LinkState = .searching
    @Published var trackTitle = ""
    @Published var trackArtist = ""
    @Published var trackAlbum = ""
    @Published var trackSource = ""
    @Published var artwork: NSImage?
    private var volumeLoad = 0
    private var checkingVolume = false
    private var lastSentVolume: Int?
    private var pendingVolume: DispatchWorkItem?
    private var checkingSource = false
    private var toggles = 0
    private var busyCount = 0
    /// Bumped by every capture start and by stop; only the newest start may become the session.
    private var startGeneration = 0

    /// Every change to the link or the capture session runs here, in order,
    /// so a slow speaker never races a later click.
    private let work = DispatchQueue(label: "soyes.model", qos: .userInitiated)
    private var link: SpeakerLink?
    private var session: StreamSession?
    var needsCleanup: Bool { link != nil || session != nil }

    init() {
        let defaults = UserDefaults.standard
        if let raw = defaults.string(forKey: "streamFormat"), let format = StreamFormat(rawValue: raw) {
            streamFormat = format
        }
        let names = defaults.dictionary(forKey: "speakerNames") as? [String: String] ?? [:]
        var hosts = defaults.stringArray(forKey: "speakerHosts")
        if hosts == nil, let host = defaults.string(forKey: "speakerHost") {
            hosts = [host] + (defaults.stringArray(forKey: "groupHosts") ?? [])
        }
        let saved = hosts ?? []
        let legacyName = defaults.string(forKey: "speakerName")
        speakers = saved.map { host in
            FoundSpeaker(name: names[host] ?? (host == saved.first ? legacyName : nil) ?? host, host: host)
        }
        selectedIDs = Set(saved)
        Task { @MainActor in
            self.applySpeakers()
            self.refresh()
        }
    }

    var menuIcon: String {
        guard isOn else { return "hifispeaker" }
        return selectedIDs.count > 1 ? "hifispeaker.2.fill" : "hifispeaker.fill"
    }

    var canStream: Bool {
        isOn || (!isBusy && !selectedIDs.isEmpty && selectedApp != nil)
    }

    var statusText: String {
        if selectedIDs.isEmpty { return "Choose a speaker" }
        if selectedApp == nil { return apps.isEmpty ? "No apps playing audio" : "Choose an app" }
        guard isOn else { return "Off" }
        return linkState.title
    }

    var selectedApp: AudioApp? {
        apps.first { $0.id == appID }
    }

    /// The speaker that receives the stream; the other selected speakers join its group.
    /// It stays the same while it is selected, so adding or removing others never
    /// interrupts playback.
    private var coordinator: FoundSpeaker? {
        if let current = link?.selected, selectedIDs.contains(current.id) { return current }
        return speakers.first { selectedIDs.contains($0.id) }
    }

    private var selectedSpeakers: [FoundSpeaker] {
        guard let lead = coordinator else { return [] }
        return [lead] + speakers.filter { selectedIDs.contains($0.id) && $0.id != lead.id }
    }

    func toggleSpeaker(_ id: String) {
        if selectedIDs.contains(id) {
            selectedIDs.remove(id)
        } else {
            selectedIDs.insert(id)
        }
        applySpeakers()
        loadVolume()
    }

    private func persistSpeakers() {
        let defaults = UserDefaults.standard
        let chosen = selectedSpeakers
        defaults.set(chosen.map(\.host), forKey: "speakerHosts")
        var names = defaults.dictionary(forKey: "speakerNames") as? [String: String] ?? [:]
        for speaker in chosen { names[speaker.host] = speaker.name }
        defaults.set(names, forKey: "speakerNames")
    }

    /// Brings the link in line with the selection. Keeps the current link when its
    /// speaker is still selected and only regroups the others; otherwise moves the
    /// stream to a new lead speaker, restarting capture if it was on.
    private func applySpeakers() {
        persistSpeakers()
        let chosen = selectedSpeakers
        guard let lead = chosen.first else {
            let oldSession = session
            let oldLink = link
            session = nil
            link = nil
            isOn = false
            startGeneration += 1
            linkState = .searching
            applyNowPlaying(nil)
            work.async {
                oldSession?.stop()
                oldLink?.close()
            }
            return
        }
        // Other speakers only join while streaming, so an idle Soyes never holds them.
        let members = isOn ? Array(chosen.dropFirst()) : []
        if let link, link.selected.id == lead.id {
            link.setMembers(members)
            return
        }
        let oldSession = session
        let oldLink = link
        let next = makeLink(lead, members: members)
        link = next
        session = nil
        let app = isOn ? selectedApp : nil
        let generation = app == nil ? 0 : nextStart()
        work.async {
            oldSession?.stop()
            oldLink?.close()
            next.open()
            guard let app else { return }
            let result = Self.startSession(link: next, app: app)
            DispatchQueue.main.async {
                self.adopt(result, link: next, generation: generation)
            }
        }
    }

    private func makeLink(_ speaker: FoundSpeaker, members: [FoundSpeaker]) -> SpeakerLink {
        let next = SpeakerLink(speaker: speaker, format: streamFormat, group: members)
        next.onState = { [weak self, weak next] state in
            DispatchQueue.main.async {
                guard let self, let next, self.link === next else { return }
                self.linkState = state
            }
        }
        next.onInfo = { [weak self, weak next] info in
            DispatchQueue.main.async {
                guard let self, let next, self.link === next else { return }
                self.applyNowPlaying(info)
            }
        }
        next.onError = { [weak self] message in
            DispatchQueue.main.async { self?.errorText = message }
        }
        applyNowPlaying(nil)
        linkState = .searching
        return next
    }

    private func applyNowPlaying(_ info: NowPlaying?) {
        trackTitle = info?.title ?? ""
        trackArtist = info?.artist ?? ""
        trackAlbum = info?.album ?? ""
        trackSource = info?.windowSource ?? ""
        artwork = info.flatMap { $0.artwork.isEmpty ? nil : NSImage(data: $0.artwork) }
    }

    func refresh() {
        refreshApps()
        refreshSpeakers()
    }

    private func refreshApps() {
        DispatchQueue.global(qos: .userInitiated).async {
            let apps = AudioApps.list().filter { !$0.name.hasPrefix("pid ") }
            DispatchQueue.main.async {
                let previousApp = self.appID
                self.apps = apps
                if let previousApp, apps.contains(where: { $0.id == previousApp }) {
                    return
                }
                if self.isOn, previousApp != nil {
                    // The streamed app left the list; leave the stream alone until the user changes it.
                    return
                }
                let saved = UserDefaults.standard.string(forKey: "appBundleID") ?? ""
                self.appID = apps.first { !saved.isEmpty && $0.bundleID == saved }?.id
                    ?? apps.first { $0.bundleID == "com.apple.Music" || $0.name.caseInsensitiveCompare("Music") == .orderedSame }?.id
                    ?? apps.first { $0.outputRunning }?.id
                    ?? apps.first?.id
                self.refreshSourcePlayback()
            }
        }
    }

    private func refreshSpeakers() {
        guard !isDiscovering else { return }
        isDiscovering = true
        let known = selectedSpeakers.map(\.host) + speakers.map(\.host)
        DispatchQueue.global(qos: .userInitiated).async {
            let found = discoverSpeakers(known: known)
            DispatchQueue.main.async {
                self.isDiscovering = false
                // A failed lookup keeps the current list instead of wiping the selection.
                guard let found, !found.isEmpty else { return }
                let before = self.selectedIDs
                self.speakers = found
                var kept = before.filter { id in found.contains { $0.id == id } }
                if before.isEmpty, let first = found.first { kept = [first.id] }
                self.selectedIDs = kept
                self.applySpeakers()
                self.loadVolume()
            }
        }
    }

    func loadVolume() {
        guard let host = coordinator?.host, !checkingVolume else { return }
        checkingVolume = true
        volumeLoad += 1
        let request = volumeLoad
        DispatchQueue.global(qos: .userInitiated).async {
            let level = try? SonosSpeaker(host: host).volume()
            DispatchQueue.main.async {
                self.checkingVolume = false
                guard self.coordinator?.host == host else {
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
        let hosts = selectedSpeakers.map(\.host)
        guard !hosts.isEmpty else { return }
        let level = Int(volume.rounded())
        guard level != lastSentVolume else { return }
        volumeLoad += 1
        lastSentVolume = level
        pendingVolume?.cancel()
        let work = DispatchWorkItem {
            for host in hosts {
                try? SonosSpeaker(host: host).setVolume(level)
            }
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

    /// Switches the captured app. While streaming, the capture moves to the new
    /// app and the speakers keep playing.
    func setApp(_ id: pid_t?) {
        guard id != appID, let app = apps.first(where: { $0.id == id }) else { return }
        appID = id
        UserDefaults.standard.set(app.bundleID, forKey: "appBundleID")
        sourceIsPlaying = false
        refreshSourcePlayback()
        guard isOn, let link else { return }
        let old = session
        session = nil
        let generation = nextStart()
        work.async {
            old?.stop()
            let result = Self.startSession(link: link, app: app)
            DispatchQueue.main.async {
                self.adopt(result, link: link, generation: generation)
            }
        }
    }

    nonisolated private static func startSession(link: SpeakerLink, app: AudioApp) -> Result<StreamSession, Error> {
        let session = StreamSession(link: link)
        do {
            try session.start(app: app)
            return .success(session)
        } catch {
            session.stop()
            return .failure(error)
        }
    }

    /// Keeps a session that finished starting only if it is the newest start and
    /// still matches what the user wants; they may have stopped, switched apps, or
    /// changed speakers meanwhile.
    private func adopt(_ result: Result<StreamSession, Error>, link: SpeakerLink, generation: Int) {
        defer { endBusy() }
        let current = generation == startGeneration && isOn && self.link === link
        switch result {
        case .success(let started):
            if current {
                let replaced = session
                session = started
                if let replaced { work.async { replaced.stop() } }
            } else {
                work.async { started.stop() }
            }
        case .failure(let error):
            guard current else { return }
            isOn = false
            errorText = error.localizedDescription
        }
    }

    private func nextStart() -> Int {
        startGeneration += 1
        busyCount += 1
        isBusy = true
        return startGeneration
    }

    private func endBusy() {
        busyCount = max(0, busyCount - 1)
        isBusy = busyCount > 0
    }

    func setStreamFormat(_ format: StreamFormat) {
        guard format != streamFormat else { return }
        streamFormat = format
        UserDefaults.standard.set(format.rawValue, forKey: "streamFormat")
        link?.setFormat(format)
    }

    func setStreaming(_ on: Bool) {
        if !on {
            stop()
            return
        }
        guard !isOn, !isBusy else { return }
        if link == nil { applySpeakers() }
        guard let link, let app = selectedApp else { return }
        isOn = true
        link.setMembers(Array(selectedSpeakers.dropFirst()))
        let generation = nextStart()
        work.async {
            let result = Self.startSession(link: link, app: app)
            DispatchQueue.main.async {
                self.adopt(result, link: link, generation: generation)
            }
        }
    }

    func stop() {
        let session = session
        self.session = nil
        isOn = false
        startGeneration += 1
        link?.setMembers([])
        work.async {
            session?.stop()
        }
    }

    func stopForQuit(_ completion: @escaping () -> Void) {
        let session = session
        let link = link
        self.session = nil
        self.link = nil
        isOn = false
        startGeneration += 1
        work.async {
            session?.stop()
            link?.close()
            DispatchQueue.main.async(execute: completion)
        }
    }
}
