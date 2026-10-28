import AudioToolbox
import Foundation

enum StreamFormat: String, CaseIterable, Identifiable {
    case wav
    case aac

    var id: String { rawValue }

    var title: String {
        switch self {
        case .wav: "WAV (Faster start)"
        case .aac: "AAC (More stable)"
        }
    }

    var path: String {
        switch self {
        case .wav: "/stream.wav"
        case .aac: "/stream.aac"
        }
    }

    var mime: String {
        switch self {
        case .wav: "audio/wav"
        case .aac: "audio/aac"
        }
    }

    static func from(path: String) -> StreamFormat {
        path == StreamFormat.aac.path ? .aac : .wav
    }

    static func isStreamPath(_ path: String) -> Bool {
        path == "/stream.wav" || path == "/stream.aac"
    }

    static func isStream(_ uri: String) -> Bool {
        uri.contains("/stream.wav") || uri.contains("/stream.aac")
    }

    static func mime(for url: String) -> String {
        url.contains("/stream.aac") ? StreamFormat.aac.mime : StreamFormat.wav.mime
    }
}

final class Streamer {
    let sampleRate: Double
    private var serverFD: Int32 = -1
    private let clients = ClientList()
    private let pcm = PCMQueue()
    private let lock = NSLock()
    private var running = true
    private var fedUntil = Date()
    private var padding = false
    private var fadeInLeft = 0
    private var lastFrame: (Int16, Int16) = (0, 0)
    private var resampler: Resampler
    private let aac: AACEncoder?
    private var aacLive = false
    private let chime: [Int16]
    private var chimeCursor: Int?
    private var greetUntil = Date.distantPast
    private var nowPlaying = Data()
    private(set) var port: UInt16 = 0
    var onListener: ((_ greeted: Bool) -> Void)?

    static func streamRate(for outputRate: Double) -> Double {
        outputRate == 44_100 ? 44_100 : 48_000
    }

    init(sampleRate: Double, sourceRate: Double, chime: [Int16]) {
        self.sampleRate = sampleRate
        self.chime = chime
        resampler = Resampler(from: sourceRate, to: sampleRate)
        aac = AACEncoder(sampleRate: sampleRate)
    }

    func start() throws {
        serverFD = try openSocket()
        Thread.detachNewThread { [weak self] in
            self?.send()
        }
        Thread.detachNewThread { [weak self] in
            self?.fillSilence()
        }
    }

    func write(_ samples: [Int16]) {
        guard !samples.isEmpty else { return }
        lock.lock()
        fedUntil = Date()
        var output = resampler.process(samples)
        if padding {
            fadeInLeft = edgeFrames
            padding = false
        }
        fadeIn(&output)
        if output.count >= 2 {
            lastFrame = (output[output.count - 2], output[output.count - 1])
        }
        pcm.append(output)
        lock.unlock()
    }

    func setSourceRate(_ rate: Double) {
        lock.lock()
        if resampler.sourceRate != rate {
            resampler = Resampler(from: rate, to: sampleRate)
        }
        lock.unlock()
    }

    func armGreeting() {
        lock.lock()
        greetUntil = Date().addingTimeInterval(10)
        lock.unlock()
    }

    func setNowPlaying(_ info: NowPlaying) {
        let body = Data(info.listing.utf8)
        lock.lock()
        nowPlaying = body
        lock.unlock()
    }

    var hasListener: Bool { clients.hasListener }

    func stop() {
        lock.lock()
        running = false
        lock.unlock()
        if serverFD >= 0 {
            close(serverFD)
            serverFD = -1
        }
        clients.closeAll()
    }

    private func send() {
        while true {
            lock.lock()
            let live = running
            lock.unlock()
            guard live else { return }
            var samples = pcm.take()
            if samples.isEmpty {
                Thread.sleep(forTimeInterval: 0.005)
                continue
            }
            mixChime(into: &samples)
            let needed = clients.formats()
            var wav = Data()
            var encoded = Data()
            if needed.contains(.wav) {
                wav = samples.withUnsafeBufferPointer { Data(buffer: $0) }
            }
            if needed.contains(.aac), let aac {
                if !aacLive {
                    aac.reset()
                    aacLive = true
                }
                encoded = aac.encode(samples)
            } else if aacLive {
                aac?.reset()
                aacLive = false
            }
            if wav.isEmpty && encoded.isEmpty { continue }
            clients.broadcast(wav: wav, aac: encoded)
        }
    }

    func dropClients(except format: StreamFormat) {
        clients.drop(except: format)
    }

    func disarmGreeting() {
        lock.lock()
        greetUntil = .distantPast
        chimeCursor = nil
        lock.unlock()
    }

    private func mixChime(into samples: inout [Int16]) {
        lock.lock()
        guard let cursor = chimeCursor else {
            lock.unlock()
            return
        }
        let count = min(samples.count, chime.count - cursor)
        for index in 0..<count {
            let mixed = Int(samples[index]) + Int(chime[cursor + index])
            samples[index] = Int16(max(-32_768, min(32_767, mixed)))
        }
        let next = cursor + count
        if next >= chime.count {
            chimeCursor = nil
            greetUntil = .distantPast
        } else {
            chimeCursor = next
        }
        lock.unlock()
    }

    private func fillSilence() {
        while true {
            Thread.sleep(forTimeInterval: 0.01)
            let now = Date()
            lock.lock()
            guard running else {
                lock.unlock()
                return
            }
            // A late capture buffer is not silence: wait longer before padding
            // mid-music, then keep the stream fed in small steps once padding.
            let gap = now.timeIntervalSince(fedUntil)
            if gap > (padding ? 0.05 : 0.2) {
                fedUntil = now
                var silence = [Int16](repeating: 0, count: Int(gap * sampleRate) * 2)
                if !padding {
                    fadeOut(&silence)
                    padding = true
                }
                pcm.append(silence)
            }
            lock.unlock()
        }
    }

    /// About 5 ms, short enough to be inaudible but long enough to avoid a click.
    private var edgeFrames: Int { Int(sampleRate * 0.005) }

    /// Ramps from the last sent frame down to zero instead of cutting to silence.
    private func fadeOut(_ silence: inout [Int16]) {
        let frames = min(edgeFrames, silence.count / 2)
        for frame in 0..<frames {
            let level = 1 - Double(frame + 1) / Double(frames)
            silence[frame * 2] = Int16(Double(lastFrame.0) * level)
            silence[frame * 2 + 1] = Int16(Double(lastFrame.1) * level)
        }
    }

    /// Continues across buffers, since one capture buffer can be shorter than the fade.
    private func fadeIn(_ samples: inout [Int16]) {
        let frames = min(fadeInLeft, samples.count / 2)
        let done = edgeFrames - fadeInLeft
        for frame in 0..<frames {
            let level = Double(done + frame) / Double(edgeFrames)
            samples[frame * 2] = Int16(Double(samples[frame * 2]) * level)
            samples[frame * 2 + 1] = Int16(Double(samples[frame * 2 + 1]) * level)
        }
        fadeInLeft -= frames
    }

    private func requestPath(_ request: Data) -> String {
        guard let text = String(data: request, encoding: .utf8) else { return "/" }
        let line = text.split(separator: "\r\n", maxSplits: 1).first ?? ""
        let parts = line.split(separator: " ")
        guard parts.count >= 2 else { return "/" }
        let target = String(parts[1])
        return target.split(separator: "?").first.map(String.init) ?? target
    }

    private func wavHeader() -> Data {
        let rate = UInt32(sampleRate)
        var header = Data()
        func append<T: FixedWidthInteger>(_ value: T) {
            withUnsafeBytes(of: value.littleEndian) { header.append(contentsOf: $0) }
        }
        header.append(contentsOf: Array("RIFF".utf8))
        append(UInt32.max)
        header.append(contentsOf: Array("WAVEfmt ".utf8))
        append(UInt32(16))
        append(UInt16(1))
        append(UInt16(2))
        append(rate)
        append(rate * 4)
        append(UInt16(4))
        append(UInt16(16))
        header.append(contentsOf: Array("data".utf8))
        append(UInt32.max)
        return header
    }

    private func openSocket() throws -> Int32 {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw PipeError.message("Could not open a streaming socket.") }
        var reuse: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size))
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = 0
        address.sin_addr.s_addr = INADDR_ANY
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard bound == 0, Darwin.listen(fd, 4) == 0 else {
            close(fd)
            throw PipeError.message("Could not listen for the speaker.")
        }
        var boundAddress = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let named = withUnsafeMutablePointer(to: &boundAddress) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &length) }
        }
        guard named == 0 else {
            close(fd)
            throw PipeError.message("Could not read the streaming port.")
        }
        port = UInt16(bigEndian: boundAddress.sin_port)

        Thread.detachNewThread { [weak self] in
            self?.acceptLoop(fd)
        }
        return fd
    }

    private func acceptLoop(_ fd: Int32) {
        while true {
            var address = sockaddr_in()
            var length = socklen_t(MemoryLayout<sockaddr_in>.size)
            let client = withUnsafeMutablePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { accept(fd, $0, &length) }
            }
            if client < 0 { break }
            var timeout = timeval(tv_sec: 1, tv_usec: 0)
            setsockopt(client, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
            var enabled: Int32 = 1
            setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &enabled, socklen_t(MemoryLayout<Int32>.size))
            setsockopt(client, IPPROTO_TCP, TCP_NODELAY, &enabled, socklen_t(MemoryLayout<Int32>.size))
            Thread.detachNewThread { [weak self] in
                self?.serve(client)
            }
        }
    }

    private func serve(_ client: Int32) {
        var request = Data()
        var byte: UInt8 = 0
        while request.count < 4096, read(client, &byte, 1) == 1 {
            request.append(byte)
            if request.suffix(4).elementsEqual([13, 10, 13, 10]) { break }
        }
        let path = requestPath(request)
        if path == "/now-playing" {
            lock.lock()
            let body = nowPlaying
            lock.unlock()
            let header = "HTTP/1.1 200 OK\r\nContent-Type: text/plain; charset=utf-8\r\nContent-Length: \(body.count)\r\nCache-Control: no-cache, no-store\r\nConnection: close\r\n\r\n"
            _ = writeAll(client, Data(header.utf8) + body)
            close(client)
            return
        }
        let format = StreamFormat.from(path: path)
        if format == .aac && aac == nil {
            let header = "HTTP/1.1 503 Service Unavailable\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
            _ = writeAll(client, Data(header.utf8))
            close(client)
            return
        }
        var response = Data("HTTP/1.1 200 OK\r\nContent-Type: \(format.mime)\r\nCache-Control: no-cache, no-store\r\nConnection: close\r\n\r\n".utf8)
        if format == .wav { response.append(wavHeader()) }
        guard writeAll(client, response) else {
            close(client)
            return
        }
        clients.add(client, format: format)
        lock.lock()
        let greet = Date() < greetUntil && !chime.isEmpty
        if greet { chimeCursor = 0 }
        lock.unlock()
        onListener?(greet)
    }
}

private struct Resampler {
    let sourceRate: Double
    private let step: Double
    private var position = 0.0
    private var last: (Int16, Int16) = (0, 0)

    init(from sourceRate: Double, to targetRate: Double) {
        self.sourceRate = sourceRate
        step = sourceRate / targetRate
    }

    mutating func process(_ input: [Int16]) -> [Int16] {
        guard step != 1 else { return input }
        let frames = input.count / 2
        guard frames > 0 else { return [] }
        var output = [Int16]()
        output.reserveCapacity(Int(Double(frames) / step + 2) * 2)
        while position < Double(frames) {
            let index = Int(position)
            let fraction = position - Double(index)
            let left0 = index == 0 ? last.0 : input[(index - 1) * 2]
            let right0 = index == 0 ? last.1 : input[(index - 1) * 2 + 1]
            let left1 = input[index * 2]
            let right1 = input[index * 2 + 1]
            output.append(Int16(Double(left0) + (Double(left1) - Double(left0)) * fraction))
            output.append(Int16(Double(right0) + (Double(right1) - Double(right0)) * fraction))
            position += step
        }
        position -= Double(frames)
        last = (input[(frames - 1) * 2], input[(frames - 1) * 2 + 1])
        return output
    }
}

private struct StreamClient {
    let fd: Int32
    let format: StreamFormat
}

final class ClientList: @unchecked Sendable {
    private let lock = NSLock()
    private var clients: [StreamClient] = []

    var hasListener: Bool {
        lock.lock()
        defer { lock.unlock() }
        return !clients.isEmpty
    }

    func formats() -> Set<StreamFormat> {
        lock.lock()
        defer { lock.unlock() }
        return Set(clients.map(\.format))
    }

    func add(_ client: Int32, format: StreamFormat) {
        lock.lock()
        clients.append(StreamClient(fd: client, format: format))
        lock.unlock()
    }

    func broadcast(wav: Data, aac: Data) {
        lock.lock()
        let current = clients
        lock.unlock()
        for client in current {
            let data = client.format == .wav ? wav : aac
            if data.isEmpty || writeAll(client.fd, data) { continue }
            remove(client.fd)
        }
    }

    func drop(except format: StreamFormat) {
        lock.lock()
        let removed = clients.filter { $0.format != format }
        clients.removeAll { $0.format != format }
        lock.unlock()
        removed.forEach { close($0.fd) }
    }

    func closeAll() {
        lock.lock()
        let current = clients
        clients.removeAll()
        lock.unlock()
        current.forEach { close($0.fd) }
    }

    private func remove(_ client: Int32) {
        lock.lock()
        let existed = clients.contains { $0.fd == client }
        clients.removeAll { $0.fd == client }
        lock.unlock()
        if existed { close(client) }
    }
}

private final class AACEncoder {
    private var converter: AudioConverterRef?
    private var pending: [Int16] = []
    private var packetStorage = [UInt8]()
    private let sampleRate: Double
    private let framesPerPacket = 1024

    init?(sampleRate: Double) {
        self.sampleRate = sampleRate
        var input = AudioStreamBasicDescription(
            mSampleRate: sampleRate,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked,
            mBytesPerPacket: 4,
            mFramesPerPacket: 1,
            mBytesPerFrame: 4,
            mChannelsPerFrame: 2,
            mBitsPerChannel: 16,
            mReserved: 0
        )
        var output = AudioStreamBasicDescription(
            mSampleRate: sampleRate,
            mFormatID: kAudioFormatMPEG4AAC,
            mFormatFlags: 0,
            mBytesPerPacket: 0,
            mFramesPerPacket: 1024,
            mBytesPerFrame: 0,
            mChannelsPerFrame: 2,
            mBitsPerChannel: 0,
            mReserved: 0
        )
        var created: AudioConverterRef?
        guard AudioConverterNew(&input, &output, &created) == noErr, let created else { return nil }
        converter = created
        var mode: UInt32 = kAudioCodecBitRateControlMode_Constant
        AudioConverterSetProperty(created, kAudioCodecPropertyBitRateControlMode, UInt32(MemoryLayout<UInt32>.size), &mode)
        var bitrate: UInt32 = 256_000
        AudioConverterSetProperty(created, kAudioConverterEncodeBitRate, UInt32(MemoryLayout<UInt32>.size), &bitrate)
        var maxPacket: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        AudioConverterGetProperty(created, kAudioConverterPropertyMaximumOutputPacketSize, &size, &maxPacket)
        if maxPacket < 16 { maxPacket = 2048 }
        packetStorage = [UInt8](repeating: 0, count: Int(maxPacket))
    }

    deinit {
        if let converter { AudioConverterDispose(converter) }
    }

    func reset() {
        pending.removeAll(keepingCapacity: true)
        if let converter { AudioConverterReset(converter) }
    }

    func encode(_ samples: [Int16]) -> Data {
        pending.append(contentsOf: samples)
        var encoded = Data()
        while pending.count >= framesPerPacket * 2 {
            let before = pending.count
            if let packet = pullPacket() {
                encoded.append(packet)
            }
            if pending.count == before { break }
        }
        return encoded
    }

    private func pullPacket() -> Data? {
        guard let converter else { return nil }
        let feed = AACFeed(samples: pending)
        var packetCount: UInt32 = 1
        var description = AudioStreamPacketDescription()
        var status: OSStatus = noErr
        feed.samples.withUnsafeBytes { input in
            feed.base = UnsafeMutableRawPointer(mutating: input.baseAddress)
            packetStorage.withUnsafeMutableBytes { raw in
                guard let base = raw.baseAddress else { return }
                var list = AudioBufferList(
                    mNumberBuffers: 1,
                    mBuffers: AudioBuffer(mNumberChannels: 2, mDataByteSize: UInt32(raw.count), mData: base)
                )
                status = AudioConverterFillComplexBuffer(
                    converter,
                    { _, ioNumberDataPackets, ioData, _, userData in
                        let feed = Unmanaged<AACFeed>.fromOpaque(userData!).takeUnretainedValue()
                        let remaining = feed.samples.count / 2 - feed.frame
                        let frames = min(Int(ioNumberDataPackets.pointee), remaining)
                        guard frames > 0, let base = feed.base else {
                            ioNumberDataPackets.pointee = 0
                            return -1
                        }
                        ioNumberDataPackets.pointee = UInt32(frames)
                        let buffers = UnsafeMutableAudioBufferListPointer(ioData)
                        buffers[0].mNumberChannels = 2
                        buffers[0].mDataByteSize = UInt32(frames * 4)
                        buffers[0].mData = base.advanced(by: feed.frame * 4)
                        feed.frame += frames
                        return noErr
                    },
                    Unmanaged.passUnretained(feed).toOpaque(),
                    &packetCount,
                    &list,
                    &description
                )
            }
        }
        if feed.frame > 0 {
            pending.removeFirst(feed.frame * 2)
        }
        guard status == noErr, packetCount > 0 else { return nil }
        let size = Int(description.mDataByteSize)
        guard size > 0, size <= packetStorage.count else { return nil }
        var packet = Data(adts(length: size))
        packet.append(contentsOf: packetStorage.prefix(size))
        return packet
    }

    private func adts(length: Int) -> [UInt8] {
        let rates = [96000, 88200, 64000, 48000, 44100, 32000, 24000, 22050, 16000, 12000, 11025, 8000]
        let index = rates.firstIndex(of: Int(sampleRate.rounded())) ?? 4
        let full = length + 7
        let profile = 1
        let channels = 2
        return [
            0xFF,
            0xF1,
            UInt8((profile << 6) | (index << 2) | (channels >> 2)),
            UInt8(((channels & 3) << 6) | ((full >> 11) & 0x03)),
            UInt8((full >> 3) & 0xFF),
            UInt8(((full & 7) << 5) | 0x1F),
            0xFC,
        ]
    }
}

private final class AACFeed {
    let samples: [Int16]
    var frame = 0
    var base: UnsafeMutableRawPointer?
    init(samples: [Int16]) { self.samples = samples }
}

@discardableResult
func writeAll(_ fd: Int32, _ data: Data) -> Bool {
    data.withUnsafeBytes { raw in
        guard let base = raw.bindMemory(to: UInt8.self).baseAddress else { return false }
        var sent = 0
        while sent < raw.count {
            let wrote = write(fd, base.advanced(by: sent), raw.count - sent)
            if wrote <= 0 { return false }
            sent += wrote
        }
        return true
    }
}

func localAddress(toward host: String) -> String {
    let fd = socket(AF_INET, SOCK_DGRAM, 0)
    guard fd >= 0 else { return "127.0.0.1" }
    defer { close(fd) }
    var remote = sockaddr_in()
    remote.sin_family = sa_family_t(AF_INET)
    remote.sin_port = UInt16(9).bigEndian
    inet_pton(AF_INET, host, &remote.sin_addr)
    let connected = withUnsafePointer(to: &remote) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
        }
    }
    guard connected == 0 else { return "127.0.0.1" }
    var local = sockaddr_in()
    var length = socklen_t(MemoryLayout<sockaddr_in>.size)
    let named = withUnsafeMutablePointer(to: &local) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &length) }
    }
    guard named == 0 else { return "127.0.0.1" }
    var buffer = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
    inet_ntop(AF_INET, &local.sin_addr, &buffer, socklen_t(INET_ADDRSTRLEN))
    return String(cString: buffer)
}
