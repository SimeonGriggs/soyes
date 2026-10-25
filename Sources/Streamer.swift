import Foundation

final class Streamer {
    let sampleRate: Double
    private var serverFD: Int32 = -1
    private let clients = ClientList()
    private let pcm = PCMQueue()
    private let lock = NSLock()
    private var running = true
    private var fedUntil = Date()
    private var resampler: Resampler
    private let chime: [Int16]
    private var chimeCursor: Int?
    private var greetUntil = Date.distantPast
    private(set) var port: UInt16 = 0
    var onListener: ((_ greeted: Bool) -> Void)?

    static func streamRate(for outputRate: Double) -> Double {
        outputRate == 44_100 ? 44_100 : 48_000
    }

    init(sampleRate: Double, sourceRate: Double, chime: [Int16]) {
        self.sampleRate = sampleRate
        self.chime = chime
        resampler = Resampler(from: sourceRate, to: sampleRate)
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
        let output = resampler.process(samples)
        lock.unlock()
        pcm.append(output)
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
            clients.broadcast(samples.withUnsafeBufferPointer { Data(buffer: $0) })
        }
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
            let gap = now.timeIntervalSince(fedUntil)
            if gap > 0.05 { fedUntil = now }
            lock.unlock()
            if gap > 0.05 {
                pcm.append([Int16](repeating: 0, count: Int(gap * sampleRate) * 2))
            }
        }
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
        let header = "HTTP/1.1 200 OK\r\nContent-Type: audio/wav\r\nCache-Control: no-cache, no-store\r\nConnection: close\r\n\r\n"
        guard writeAll(client, Data(header.utf8) + wavHeader()) else {
            close(client)
            return
        }
        clients.add(client)
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

final class ClientList: @unchecked Sendable {
    private let lock = NSLock()
    private var clients: [Int32] = []

    var hasListener: Bool {
        lock.lock()
        defer { lock.unlock() }
        return !clients.isEmpty
    }

    func add(_ client: Int32) {
        lock.lock()
        clients.append(client)
        lock.unlock()
    }

    func broadcast(_ data: Data) {
        lock.lock()
        let current = clients
        lock.unlock()
        for client in current where !writeAll(client, data) {
            remove(client)
        }
    }

    func closeAll() {
        lock.lock()
        let current = clients
        clients.removeAll()
        lock.unlock()
        current.forEach { close($0) }
    }

    private func remove(_ client: Int32) {
        lock.lock()
        clients.removeAll { $0 == client }
        lock.unlock()
        close(client)
    }
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
