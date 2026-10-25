import Foundation

enum LinkState: Equatable {
    case searching
    case unreachable
    case inUse
    case available
    case connecting
    case buffering
    case paused
    case connected

    var title: String {
        switch self {
        case .searching, .connecting: return "Connecting"
        case .unreachable: return "Not found"
        case .inUse: return "In use"
        case .available: return "Available"
        case .buffering: return "Buffering"
        case .paused: return "Paused"
        case .connected: return "Connected"
        }
    }

    var pulses: Bool {
        self == .searching || self == .connecting || self == .buffering
    }
}

private enum Chime {
    static func render(rate: Double) -> [Int16] {
        let notes: [(frequency: Double, start: Double)] = [(659.25, 0), (987.77, 0.13)]
        let count = Int(rate * 0.9)
        var samples = [Int16]()
        samples.reserveCapacity(count * 2)
        for frame in 0..<count {
            let time = Double(frame) / rate
            var level = 0.0
            for note in notes where time >= note.start {
                let into = time - note.start
                let attack = min(1, into / 0.006)
                level += sin(2 * Double.pi * note.frequency * into) * attack * exp(-into * 6)
            }
            let value = Int16(max(-1.0, min(1.0, level * 0.3)) * 32_767)
            samples.append(value)
            samples.append(value)
        }
        return samples
    }
}

final class SpeakerLink: @unchecked Sendable {
    let selected: FoundSpeaker
    private let player: SonosSpeaker
    private var speaker: SonosSpeaker?
    private var streamer: Streamer?
    private var streamURL: String?
    private var sourceRate: Double?
    private var playback: Playback?
    private var wasMuted: Bool?
    private var held = false
    private var engaging = false
    private var closed = false
    private var muted = false
    private var unmuteAt: Date?
    private var lastSound = Date.distantPast
    private var transport = ""
    private var listenerSince: Date?
    private var listenerGreeted = false
    private var delay: TimeInterval = 0.7
    private var beaconUntil = Date.distantPast
    private var streamInfo: NowPlaying?
    private var published: NowPlaying?
    private var lastInfoFetch = Date.distantPast
    private let lock = NSLock()
    private let commands = DispatchQueue(label: "soyes.speaker")
    private let beaconDone = DispatchSemaphore(value: 0)
    var onState: ((LinkState) -> Void)?
    var onInfo: ((NowPlaying?) -> Void)?
    var onError: ((String) -> Void)?

    init(speaker: FoundSpeaker) {
        selected = speaker
        player = SonosSpeaker(host: speaker.host)
    }

    var isHeld: Bool {
        lock.lock()
        defer { lock.unlock() }
        return held
    }

    func open() {
        onState?(.searching)
        Thread.detachNewThread { [weak self] in
            self?.runBeacon()
        }
        Thread.detachNewThread { [weak self] in
            self?.monitor()
        }
    }

    func close() {
        lock.lock()
        if closed {
            lock.unlock()
            return
        }
        closed = true
        lock.unlock()
        _ = beaconDone.wait(timeout: .now() + 1)
        commands.sync {
            lock.lock()
            let restore = held ? speaker : nil
            let playback = playback
            let unmute = wasMuted.map { $0 != muted } ?? muted
            let original = wasMuted ?? false
            held = false
            lock.unlock()
            if let restore {
                if let playback { restore.restore(playback) }
                if unmute { try? restore.setMute(original) }
            }
        }
        streamer?.stop()
    }

    func setStreamInfo(_ info: NowPlaying) {
        lock.lock()
        streamInfo = info
        let streamer = streamer
        let active = held
        lock.unlock()
        streamer?.setNowPlaying(info)
        if active { publish(info) }
    }

    func setSourceRate(_ rate: Double) {
        lock.lock()
        sourceRate = rate
        let streamer = streamer
        lock.unlock()
        streamer?.setSourceRate(rate)
    }

    func feed(_ samples: [Int16]) {
        var peak = 0
        var index = 0
        while index < samples.count {
            let value = Int(samples[index])
            peak = max(peak, value < 0 ? -value : value)
            index += 64
        }
        if peak > 400 {
            noteSound()
        }
        streamer?.write(samples)
    }

    func cue() {
        let now = Date()
        lock.lock()
        beaconUntil = max(beaconUntil, now.addingTimeInterval(6))
        let target = earlierUnmute(now: now)
        let reconnect = needsReconnect
        lock.unlock()
        if let target { scheduleUnmute(at: target) }
        if reconnect { hold(greet: true) }
    }

    func pause() {
        lock.lock()
        beaconUntil = .distantPast
        guard held, !closed else {
            lock.unlock()
            return
        }
        let send = !muted
        let reschedule = send || unmuteAt != nil
        muted = true
        let speaker = speaker
        let drained = max(lastSound, Date()).addingTimeInterval(delay + 0.3)
        lock.unlock()
        guard let speaker else { return }
        if send {
            commands.async {
                try? speaker.setMute(true)
            }
        }
        if reschedule {
            scheduleUnmute(at: drained)
        }
    }

    func hold(greet: Bool) {
        lock.lock()
        let start = !engaging && !closed
        if start {
            engaging = true
            if greet { beaconUntil = max(beaconUntil, Date().addingTimeInterval(10)) }
        }
        lock.unlock()
        guard start else { return }
        onState?(.connecting)
        commands.async { [weak self] in
            self?.engage(greet: greet)
        }
    }

    private func earlierUnmute(now: Date) -> Date? {
        guard muted else { return nil }
        let target = max(now, lastSound.addingTimeInterval(delay))
        if let unmuteAt, unmuteAt <= target { return nil }
        return target
    }

    private var needsReconnect: Bool {
        !closed && (!held || transport == "STOPPED" || transport == "PAUSED_PLAYBACK")
    }

    private func noteSound() {
        let now = Date()
        lock.lock()
        let onset = now.timeIntervalSince(lastSound) > 1
        var target: Date?
        var reconnect = false
        if onset {
            target = earlierUnmute(now: now)
            if beaconUntil > now, transport == "PLAYING" {
                beaconUntil = now.addingTimeInterval(delay)
            }
            reconnect = needsReconnect
        }
        lastSound = now
        lock.unlock()
        if let target { scheduleUnmute(at: target) }
        if reconnect { hold(greet: true) }
    }

    private func scheduleUnmute(at target: Date) {
        lock.lock()
        unmuteAt = target
        lock.unlock()
        commands.asyncAfter(deadline: .now() + max(0, target.timeIntervalSinceNow)) { [weak self] in
            guard let self else { return }
            self.lock.lock()
            let due = self.muted && (self.unmuteAt.map { $0 <= Date() } ?? false)
            if due {
                self.muted = false
                self.unmuteAt = nil
            }
            let speaker = self.speaker
            self.lock.unlock()
            if due { try? speaker?.setMute(false) }
        }
    }

    private func prepareStreamer() throws -> Streamer {
        lock.lock()
        let existing = self.streamer
        let outputRate = defaultOutputSampleRate()
        let source = sourceRate ?? outputRate
        lock.unlock()
        if let existing { return existing }
        let rate = Streamer.streamRate(for: outputRate)
        let streamer = Streamer(sampleRate: rate, sourceRate: source, chime: Chime.render(rate: rate))
        streamer.onListener = { [weak self] greeted in
            guard let self else { return }
            self.lock.lock()
            self.listenerSince = Date()
            self.listenerGreeted = greeted
            self.lock.unlock()
        }
        try streamer.start()
        lock.lock()
        streamURL = "http://\(localAddress(toward: selected.host)):\(streamer.port)/stream.wav"
        self.streamer = streamer
        let latest = sourceRate
        let info = streamInfo ?? NowPlaying(computerName: NowPlaying.thisComputer)
        streamInfo = info
        lock.unlock()
        streamer.setNowPlaying(info)
        if let latest { streamer.setSourceRate(latest) }
        return streamer
    }

    private func engage(greet: Bool) {
        defer {
            lock.lock()
            engaging = false
            lock.unlock()
        }
        lock.lock()
        let cancelled = closed
        let wasHeld = held
        let resolved = speaker
        lock.unlock()
        guard !cancelled else { return }
        var speaker = resolved ?? player
        if resolved == nil {
            speaker.host = player.coordinator()
        }
        let streamer: Streamer
        do {
            streamer = try prepareStreamer()
        } catch {
            onError?(error.localizedDescription)
            return
        }
        guard let url = streamURL else { return }
        if greet { streamer.armGreeting() }
        var playback: Playback?
        var wasMuted: Bool?
        if !wasHeld {
            playback = try? speaker.prepare()
            wasMuted = try? speaker.isMuted()
        }
        lock.lock()
        self.speaker = speaker
        if !wasHeld {
            self.playback = playback
            self.wasMuted = wasMuted
            muted = wasMuted ?? false
        }
        let cancelledNow = closed
        lock.unlock()
        guard !cancelledNow else { return }
        do {
            lock.lock()
            let info = streamInfo ?? NowPlaying(computerName: NowPlaying.thisComputer)
            lock.unlock()
            try speaker.play(url: url, info: info)
            lock.lock()
            held = true
            transport = "TRANSITIONING"
            let unmute = greet && muted
            if unmute {
                muted = false
                unmuteAt = nil
            }
            lock.unlock()
            if unmute { try? speaker.setMute(false) }
        } catch {
            onState?(.unreachable)
        }
    }

    private func monitor() {
        var triedAuto = false
        var wasPlaying = false
        var checks = 0
        while true {
            lock.lock()
            if closed {
                lock.unlock()
                return
            }
            var speaker = self.speaker
            let busy = engaging
            lock.unlock()

            if speaker == nil {
                var resolved = player
                resolved.host = player.coordinator()
                lock.lock()
                if self.speaker == nil { self.speaker = resolved }
                speaker = self.speaker
                lock.unlock()
            }
            guard let speaker else { continue }
            let state = speaker.transportState()

            lock.lock()
            let isHeld = held
            let ours = streamURL
            let listening = streamer?.hasListener ?? false
            if state != "unknown" { transport = state }
            lock.unlock()

            if state == "unknown" {
                if !busy { onState?(.unreachable) }
                publish(nil)
                Thread.sleep(forTimeInterval: 1.5)
                continue
            }

            noteDisplay(on: speaker, visible: isHeld || state == "PLAYING" || state == "TRANSITIONING")

            if !isHeld {
                if busy {
                    onState?(.connecting)
                } else if !triedAuto {
                    triedAuto = true
                    if state != "PLAYING" && state != "TRANSITIONING" {
                        hold(greet: false)
                        Thread.sleep(forTimeInterval: 0.1)
                        continue
                    }
                    onState?(.inUse)
                } else {
                    onState?(state == "PLAYING" || state == "TRANSITIONING" ? .inUse : .available)
                }
                wasPlaying = false
                Thread.sleep(forTimeInterval: busy ? 0.1 : 1.5)
                continue
            }

            checks += 1
            if checks % 3 == 0, let ours, let current = speaker.currentURI(), current != ours {
                lock.lock()
                let original = wasMuted ?? false
                if muted != original {
                    commands.async { try? speaker.setMute(original) }
                }
                held = false
                playback = nil
                wasMuted = nil
                muted = false
                unmuteAt = nil
                lock.unlock()
                onState?(.inUse)
                continue
            }

            let playing = state == "PLAYING"
            lock.lock()
            if playing, !wasPlaying, let since = listenerSince {
                delay = min(8, max(0.2, Date().timeIntervalSince(since)))
                listenerSince = nil
                if listenerGreeted {
                    beaconUntil = .distantPast
                }
            }
            lock.unlock()
            wasPlaying = playing
            if playing {
                onState?(.connected)
            } else if state == "TRANSITIONING" || (listening && state != "STOPPED") {
                onState?(.buffering)
            } else {
                onState?(.paused)
            }
            Thread.sleep(forTimeInterval: playing ? 0.5 : 0.1)
        }
    }

    private func noteDisplay(on speaker: SonosSpeaker, visible: Bool) {
        guard visible else {
            publish(nil)
            return
        }
        lock.lock()
        let owned = held ? streamInfo : nil
        lock.unlock()
        if let owned, !owned.isEmpty {
            publish(owned)
            return
        }
        let now = Date()
        guard now.timeIntervalSince(lastInfoFetch) > 1 else { return }
        lastInfoFetch = now
        if let info = speaker.nowPlaying() {
            publish(info)
        }
    }

    private func publish(_ info: NowPlaying?) {
        let shown = info?.isEmpty == false ? info : nil
        lock.lock()
        let changed = shown != published
        if changed { published = shown }
        lock.unlock()
        if changed { onInfo?(shown) }
    }

    private func runBeacon() {
        defer { beaconDone.signal() }
        let original = (try? player.isLightOn()) ?? true
        var lit = original
        while true {
            lock.lock()
            let done = closed
            let active = Date() < beaconUntil
            lock.unlock()
            if done || !active {
                if lit != original {
                    try? player.setLight(original)
                    lit = original
                }
                if done { return }
                Thread.sleep(forTimeInterval: 0.03)
                continue
            }
            lit.toggle()
            try? player.setLight(lit)
            Thread.sleep(forTimeInterval: 0.18)
        }
    }
}

final class StreamSession: @unchecked Sendable {
    private let link: SpeakerLink
    private let capture = Capture()
    private var app: AudioApp?
    private var stopped = false
    private let lock = NSLock()

    init(link: SpeakerLink) {
        self.link = link
    }

    func start(app: AudioApp) throws {
        self.app = app
        try capture.open(objectIDs: app.objectIDs, mute: true) { [link] samples in
            link.feed(samples)
        }
        link.setSourceRate(capture.sampleRate)
        if link.isHeld {
            link.setStreamInfo(NowPlaying(appName: app.name, computerName: NowPlaying.thisComputer))
            link.cue()
        } else {
            if let info = SourcePlayback.nowPlaying(app) {
                link.setStreamInfo(info)
            }
            link.hold(greet: true)
        }
        try capture.begin()
        Thread.detachNewThread { [weak self] in
            self?.watchSource()
        }
    }

    func stop() {
        lock.lock()
        if stopped {
            lock.unlock()
            return
        }
        stopped = true
        lock.unlock()
        capture.stop()
        if let app {
            link.setStreamInfo(NowPlaying(appName: app.name, computerName: NowPlaying.thisComputer))
        }
        link.pause()
    }

    private func watchSource() {
        guard let app else { return }
        var running = SourcePlayback.isPlaying(app)
        var lastInfo: NowPlaying?
        var lastInfoAt = Date.distantPast
        while true {
            Thread.sleep(forTimeInterval: 0.1)
            lock.lock()
            let done = stopped
            lock.unlock()
            if done { return }
            let nowRunning = SourcePlayback.isPlaying(app)
            if running && !nowRunning {
                link.pause()
            } else if !running && nowRunning {
                link.cue()
            }
            let now = Date()
            if lastInfo == nil || running != nowRunning || now.timeIntervalSince(lastInfoAt) > 2 {
                lastInfoAt = now
                if let info = SourcePlayback.nowPlaying(app), info != lastInfo {
                    lock.lock()
                    let finished = stopped
                    lock.unlock()
                    if finished { return }
                    lastInfo = info
                    link.setStreamInfo(info)
                }
            }
            running = nowRunning
        }
    }
}
