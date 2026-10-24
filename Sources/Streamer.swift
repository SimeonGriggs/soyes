import Foundation

final class Streamer {
    private var ffmpeg: Process?
    private var input: FileHandle?
    private var serverFD: Int32 = -1
    private let clients = ClientList()
    private var running = true
    private(set) var port: UInt16 = 0
    private let gotAudio = DispatchSemaphore(value: 0)
    private var announcedAudio = false
    private let pcm = PCMQueue()
    private(set) var pcmFrames = 0
    private(set) var mp3Bytes = 0
    private(set) var ffmpegError = ""

    func start(sampleRate: Double) throws {
        let ffmpegURL = ffmpegExecutable()
        guard FileManager.default.isExecutableFile(atPath: ffmpegURL) else {
            throw PipeError.message("ffmpeg is not installed. Install it with Homebrew, then run this again.")
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: ffmpegURL)
        process.arguments = [
            "-nostdin", "-hide_banner", "-loglevel", "error",
            "-f", "s16le", "-ar", String(Int(sampleRate.rounded())), "-ac", "2", "-i", "pipe:0",
            "-c:a", "libmp3lame", "-b:a", "160k", "-ar", "44100", "-ac", "2",
            "-f", "mp3", "-write_xing", "0", "-id3v2_version", "0",
            "pipe:1",
        ]
        let inputPipe = Pipe()
        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.standardInput = inputPipe
        process.standardOutput = outputPipe
        process.standardError = errorPipe
        try process.run()
        ffmpeg = process
        input = inputPipe.fileHandleForWriting

        Thread.detachNewThread { [weak self] in
            self?.readEncodedAudio(outputPipe.fileHandleForReading)
        }
        Thread.detachNewThread { [weak self] in
            self?.writePCM(inputPipe.fileHandleForWriting)
        }
        Thread.detachNewThread { [weak self] in
            let data = errorPipe.fileHandleForReading.readDataToEndOfFile()
            if let text = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
               !text.isEmpty {
                self?.ffmpegError = text
                fputs("ffmpeg: \(text)\n", stderr)
            }
        }

        serverFD = try listen()
    }

    func waitForAudio(timeout: TimeInterval) -> Bool {
        gotAudio.wait(timeout: .now() + timeout) == .success
    }

    func write(_ samples: [Int16]) {
        guard !samples.isEmpty else { return }
        pcmFrames += samples.count / 2
        pcm.append(samples)
    }

    private func writePCM(_ handle: FileHandle) {
        while running {
            let samples = pcm.take()
            if samples.isEmpty {
                Thread.sleep(forTimeInterval: 0.01)
                continue
            }
            samples.withUnsafeBufferPointer { buffer in
                guard let base = buffer.baseAddress else { return }
                let data = Data(bytes: base, count: buffer.count * MemoryLayout<Int16>.size)
                do {
                    try handle.write(contentsOf: data)
                } catch {
                    ffmpegError = error.localizedDescription
                    return
                }
            }
        }
    }

    func stop() {
        running = false
        try? input?.close()
        input = nil
        ffmpeg?.terminate()
        ffmpeg = nil
        if serverFD >= 0 {
            close(serverFD)
            serverFD = -1
        }
        clients.closeAll()
    }

    private func readEncodedAudio(_ handle: FileHandle) {
        while running {
            let data = handle.availableData
            if data.isEmpty { break }
            mp3Bytes += data.count
            if !announcedAudio {
                announcedAudio = true
                gotAudio.signal()
            }
            clients.broadcast(data)
        }
    }

    private func listen() throws -> Int32 {
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
        while running {
            var address = sockaddr_in()
            var length = socklen_t(MemoryLayout<sockaddr_in>.size)
            let client = withUnsafeMutablePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { accept(fd, $0, &length) }
            }
            if client < 0 { break }
            var timeout = timeval(tv_sec: 1, tv_usec: 0)
            setsockopt(client, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
            var noSignal: Int32 = 1
            setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout<Int32>.size))
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
        let header = "HTTP/1.1 200 OK\r\nContent-Type: audio/mpeg\r\nCache-Control: no-cache, no-store\r\nicy-name: Sonos Pipe\r\nicy-br: 160\r\nConnection: close\r\n\r\n"
        guard writeAll(client, Data(header.utf8)) else {
            close(client)
            return
        }
        clients.add(client)
    }

    private func ffmpegExecutable() -> String {
        for path in ["/opt/homebrew/bin/ffmpeg", "/usr/local/bin/ffmpeg"] {
            if FileManager.default.isExecutableFile(atPath: path) { return path }
        }
        return "/opt/homebrew/bin/ffmpeg"
    }
}

final class ClientList: @unchecked Sendable {
    private let lock = NSLock()
    private var clients: [Int32] = []
    private var recent = Data()

    func add(_ client: Int32) {
        lock.lock()
        let snapshot = recent
        clients.append(client)
        lock.unlock()
        if !snapshot.isEmpty, !writeAll(client, snapshot) {
            remove(client)
        }
    }

    func broadcast(_ data: Data) {
        lock.lock()
        recent.append(data)
        if recent.count > 32_000 {
            recent.removeFirst(recent.count - 32_000)
        }
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
