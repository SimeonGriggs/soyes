import Foundation

struct SonosSpeaker {
    var host: String

    func uuid() -> String? {
        guard let description = try? get("http://\(host):1400/xml/device_description.xml") else { return nil }
        let udn = (tag(description, "UDN") ?? "").replacingOccurrences(of: "uuid:", with: "")
        return udn.isEmpty ? nil : udn
    }

    func join(to coordinatorUUID: String) throws {
        _ = try soap(
            path: "/MediaRenderer/AVTransport/Control",
            service: "AVTransport",
            action: "SetAVTransportURI",
            body: "<InstanceID>0</InstanceID><CurrentURI>x-rincon:\(coordinatorUUID)</CurrentURI><CurrentURIMetaData></CurrentURIMetaData>"
        )
        _ = try soap(
            path: "/MediaRenderer/AVTransport/Control",
            service: "AVTransport",
            action: "Play",
            body: "<InstanceID>0</InstanceID><Speed>1</Speed>"
        )
    }

    func leaveGroup() throws {
        _ = try soap(
            path: "/MediaRenderer/AVTransport/Control",
            service: "AVTransport",
            action: "BecomeCoordinatorOfStandaloneGroup",
            body: "<InstanceID>0</InstanceID>"
        )
    }

    func prepare() throws -> Playback {
        let media = try soap(path: "/MediaRenderer/AVTransport/Control", service: "AVTransport", action: "GetMediaInfo", body: "<InstanceID>0</InstanceID>")
        return Playback(
            uri: tag(media, "CurrentURI") ?? "",
            metadata: tag(media, "CurrentURIMetaData") ?? "",
            wasPlaying: transportState() == "PLAYING"
        )
    }

    func isMuted() throws -> Bool {
        try tag(
            soap(path: "/MediaRenderer/RenderingControl/Control", service: "RenderingControl", action: "GetMute", body: "<InstanceID>0</InstanceID><Channel>Master</Channel>"),
            "CurrentMute"
        ) == "1"
    }

    func setMute(_ muted: Bool) throws {
        _ = try soap(
            path: "/MediaRenderer/RenderingControl/Control",
            service: "RenderingControl",
            action: "SetMute",
            body: "<InstanceID>0</InstanceID><Channel>Master</Channel><DesiredMute>\(muted ? 1 : 0)</DesiredMute>"
        )
    }

    func isLightOn() throws -> Bool {
        try tag(
            soap(path: "/DeviceProperties/Control", service: "DeviceProperties", action: "GetLEDState", body: ""),
            "CurrentLEDState"
        ) == "On"
    }

    func setLight(_ on: Bool) throws {
        _ = try soap(
            path: "/DeviceProperties/Control",
            service: "DeviceProperties",
            action: "SetLEDState",
            body: "<DesiredLEDState>\(on ? "On" : "Off")</DesiredLEDState>"
        )
    }

    func volume() throws -> Int {
        let level = try tag(
            soap(path: "/MediaRenderer/RenderingControl/Control", service: "RenderingControl", action: "GetVolume", body: "<InstanceID>0</InstanceID><Channel>Master</Channel>"),
            "CurrentVolume"
        ) ?? "0"
        return Int(level) ?? 0
    }

    func setVolume(_ level: Int) throws {
        let clamped = min(100, max(0, level))
        _ = try soap(
            path: "/MediaRenderer/RenderingControl/Control",
            service: "RenderingControl",
            action: "SetVolume",
            body: "<InstanceID>0</InstanceID><Channel>Master</Channel><DesiredVolume>\(clamped)</DesiredVolume>"
        )
    }

    func stopPlayback() throws {
        _ = try soap(
            path: "/MediaRenderer/AVTransport/Control",
            service: "AVTransport",
            action: "Stop",
            body: "<InstanceID>0</InstanceID>"
        )
    }

    func currentURI() -> String? {
        try? tag(soap(path: "/MediaRenderer/AVTransport/Control", service: "AVTransport", action: "GetMediaInfo", body: "<InstanceID>0</InstanceID>"), "CurrentURI")
    }

    func nowPlaying() -> NowPlaying? {
        guard let media = try? soap(path: "/MediaRenderer/AVTransport/Control", service: "AVTransport", action: "GetMediaInfo", body: "<InstanceID>0</InstanceID>") else {
            return nil
        }
        var uri = tag(media, "CurrentURI") ?? ""
        if uri.contains("&") { uri = unescape(uri) }
        if let live = NowPlaying.fetchLive(from: uri) { return live }
        let stored = NowPlaying.decode(tag(media, "CurrentURIMetaData") ?? "")
        if StreamFormat.isStream(uri) { return stored ?? NowPlaying() }
        if let position = try? soap(path: "/MediaRenderer/AVTransport/Control", service: "AVTransport", action: "GetPositionInfo", body: "<InstanceID>0</InstanceID>"),
           let track = NowPlaying.decode(tag(position, "TrackMetaData") ?? ""),
           !track.title.isEmpty {
            return track
        }
        return stored ?? NowPlaying()
    }

    func play(url: String, info: NowPlaying) throws {
        let didl = info.didl(stream: url)
        _ = try soap(
            path: "/MediaRenderer/AVTransport/Control",
            service: "AVTransport",
            action: "SetAVTransportURI",
            body: "<InstanceID>0</InstanceID><CurrentURI>\(xmlEscape(url))</CurrentURI><CurrentURIMetaData>\(xmlEscape(didl))</CurrentURIMetaData>"
        )
        _ = try soap(
            path: "/MediaRenderer/AVTransport/Control",
            service: "AVTransport",
            action: "Play",
            body: "<InstanceID>0</InstanceID><Speed>1</Speed>"
        )
    }

    func transportState() -> String {
        (try? tag(soap(path: "/MediaRenderer/AVTransport/Control", service: "AVTransport", action: "GetTransportInfo", body: "<InstanceID>0</InstanceID>"), "CurrentTransportState")) ?? "unknown"
    }

    func restore(_ playback: Playback) {
        guard !playback.uri.isEmpty else {
            try? stopPlayback()
            return
        }
        do {
            _ = try soap(
                path: "/MediaRenderer/AVTransport/Control",
                service: "AVTransport",
                action: "SetAVTransportURI",
                body: "<InstanceID>0</InstanceID><CurrentURI>\(xmlEscape(playback.uri))</CurrentURI><CurrentURIMetaData>\(playback.metadata)</CurrentURIMetaData>"
            )
            if playback.wasPlaying {
                _ = try soap(
                    path: "/MediaRenderer/AVTransport/Control",
                    service: "AVTransport",
                    action: "Play",
                    body: "<InstanceID>0</InstanceID><Speed>1</Speed>"
                )
                print("Previous audio resumed.")
            } else {
                print("Previous source restored.")
            }
        } catch {
            fputs("Could not restore the previous source: \(error)\n", stderr)
        }
    }

    func rooms() -> [FoundSpeaker]? {
        guard let topology = try? soap(path: "/ZoneGroupTopology/Control", service: "ZoneGroupTopology", action: "GetZoneGroupState", body: ""),
              let state = tag(topology, "ZoneGroupState") else { return nil }
        let xml = unescape(state)
        var found: [FoundSpeaker] = []
        for chunk in xml.components(separatedBy: "<ZoneGroupMember ").dropFirst() {
            let member = chunk.prefix { $0 != ">" }
            guard attribute("Invisible", in: String(member)) != "1",
                  let name = attribute("ZoneName", in: String(member)),
                  let location = attribute("Location", in: String(member)),
                  let host = URL(string: location)?.host,
                  !found.contains(where: { $0.host == host }) else { continue }
            found.append(FoundSpeaker(name: name, host: host))
        }
        return found.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    func coordinator() -> String {
        guard let description = try? get("http://\(host):1400/xml/device_description.xml") else { return host }
        let udn = (tag(description, "UDN") ?? "").replacingOccurrences(of: "uuid:", with: "")
        guard !udn.isEmpty,
              let topology = try? soap(path: "/ZoneGroupTopology/Control", service: "ZoneGroupTopology", action: "GetZoneGroupState", body: ""),
              let state = tag(topology, "ZoneGroupState") else { return host }
        let xml = unescape(state)
        for group in xml.components(separatedBy: "<ZoneGroup>") where group.contains(udn) {
            for member in group.components(separatedBy: "<ZoneGroupMember ") where member.contains("Coordinator=\"true\"") {
                guard let uuid = attribute("UUID", in: member) else { continue }
                if uuid == udn { return host }
                if let location = attribute("Location", in: member),
                   let url = URL(string: location),
                   let coordinatorHost = url.host {
                    return coordinatorHost
                }
            }
        }
        return host
    }

    private func soap(path: String, service: String, action: String, body: String) throws -> String {
        let envelope = """
        <?xml version="1.0" encoding="utf-8"?>\
        <s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/" s:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/">\
        <s:Body><u:\(action) xmlns:u="urn:schemas-upnp-org:service:\(service):1">\(body)</u:\(action)></s:Body></s:Envelope>
        """
        var request = URLRequest(url: URL(string: "http://\(host):1400\(path)")!)
        request.httpMethod = "POST"
        request.timeoutInterval = 5
        request.setValue("text/xml; charset=utf-8", forHTTPHeaderField: "Content-Type")
        request.setValue("\"urn:schemas-upnp-org:service:\(service):1#\(action)\"", forHTTPHeaderField: "SOAPACTION")
        request.httpBody = Data(envelope.utf8)
        return try send(request)
    }

    private func get(_ url: String) throws -> String {
        var request = URLRequest(url: URL(string: url)!)
        request.timeoutInterval = 5
        return try send(request)
    }

    private func send(_ request: URLRequest) throws -> String {
        var payload: Result<(Int, String), Error>?
        let done = DispatchSemaphore(value: 0)
        URLSession.shared.dataTask(with: request) { data, response, error in
            if let error {
                payload = .failure(error)
            } else {
                let code = (response as? HTTPURLResponse)?.statusCode ?? 0
                let text = String(data: data ?? Data(), encoding: .utf8) ?? ""
                payload = .success((code, text))
            }
            done.signal()
        }.resume()
        _ = done.wait(timeout: .now() + 6)
        switch payload {
        case .success(let response) where (200..<300).contains(response.0):
            return response.1
        case .success(let response):
            let detail = tag(response.1, "errorDescription") ?? tag(response.1, "errorCode") ?? response.1
            throw PipeError.message("The speaker refused \(request.httpMethod ?? "the request") (\(response.0)): \(detail)")
        case .failure(let error):
            throw error
        case .none:
            throw PipeError.message("The speaker did not respond.")
        }
    }
}

struct Playback {
    var uri: String
    var metadata: String
    var wasPlaying: Bool
}

struct NowPlaying: Equatable {
    var appName: String
    var computerName: String
    var title: String
    var artist: String
    var album: String
    var artwork: Data

    init(appName: String = "", computerName: String = "", title: String = "", artist: String = "", album: String = "", artwork: Data = Data()) {
        self.appName = Self.clean(appName)
        self.computerName = Self.clean(computerName)
        self.title = Self.clean(title)
        self.artist = Self.clean(artist)
        self.album = Self.clean(album)
        self.artwork = artwork
    }

    var isEmpty: Bool {
        appName.isEmpty && computerName.isEmpty && title.isEmpty && artist.isEmpty && album.isEmpty
    }

    var sourceText: String {
        if !appName.isEmpty && !computerName.isEmpty { return "\(appName) on \(computerName)" }
        return appName.isEmpty ? computerName : appName
    }

    var windowSource: String {
        isThisComputer ? "" : sourceText
    }

    private var isThisComputer: Bool {
        let here = Self.clean(Self.thisComputer)
        guard !computerName.isEmpty, !here.isEmpty else { return false }
        return computerName.caseInsensitiveCompare(here) == .orderedSame
    }

    var summary: String {
        guard !title.isEmpty else { return sourceText }
        let headline = artist.isEmpty ? title : "\(title) — \(artist)"
        let detail = [album, sourceText].filter { !$0.isEmpty }.joined(separator: " · ")
        return detail.isEmpty ? headline : "\(headline)\n\(detail)"
    }

    var listing: String {
        ["1", appName, computerName, title, artist, album].joined(separator: "\n") + "\n"
    }

    func didl(stream url: String) -> String {
        let shownTitle: String
        let shownCreator: String
        if !title.isEmpty {
            shownTitle = title
            if artist.isEmpty {
                shownCreator = sourceText
            } else if sourceText.isEmpty {
                shownCreator = artist
            } else {
                shownCreator = "\(artist) · \(sourceText)"
            }
        } else if !sourceText.isEmpty {
            shownTitle = sourceText
            shownCreator = ""
        } else {
            shownTitle = "Soyes"
            shownCreator = ""
        }
        var item = "<dc:title>\(xmlEscape(shownTitle))</dc:title>"
        if !shownCreator.isEmpty { item += "<dc:creator>\(xmlEscape(shownCreator))</dc:creator>" }
        if !title.isEmpty && !album.isEmpty { item += "<upnp:album>\(xmlEscape(album))</upnp:album>" }
        let mime = StreamFormat.mime(for: url)
        return "<DIDL-Lite xmlns:dc=\"http://purl.org/dc/elements/1.1/\" xmlns:upnp=\"urn:schemas-upnp-org:metadata-1-0/upnp/\" xmlns:r=\"urn:schemas-rinconnetworks-com:metadata-1-0/\" xmlns=\"urn:schemas-upnp-org:metadata-1-0/DIDL-Lite/\"><item id=\"1\" parentID=\"-1\" restricted=\"true\">\(item)<upnp:class>object.item.audioItem.audioBroadcast</upnp:class><desc id=\"cdudn\" nameSpace=\"urn:schemas-rinconnetworks-com:metadata-1-0/\">SA_RINCON65031_</desc><res protocolInfo=\"http-get:*:\(mime):*\">\(xmlEscape(url))</res></item></DIDL-Lite>"
    }

    static var thisComputer: String {
        let sharing = Host.current().localizedName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !sharing.isEmpty { return sharing }
        let host = ProcessInfo.processInfo.hostName
        if let short = host.split(separator: ".").first, !short.isEmpty { return String(short) }
        return host
    }

    static func parseListing(_ text: String) -> NowPlaying? {
        var lines = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)
        if lines.last?.isEmpty == true { lines.removeLast() }
        guard lines.first == "1" else { return nil }
        while lines.count < 6 { lines.append("") }
        let info = NowPlaying(appName: lines[1], computerName: lines[2], title: lines[3], artist: lines[4], album: lines[5])
        return info.isEmpty ? nil : info
    }

    static func decode(_ metadata: String) -> NowPlaying? {
        var xml = metadata.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !xml.isEmpty, xml != "NOT_IMPLEMENTED" else { return nil }
        for _ in 0..<3 {
            if xml.contains(":title>") || xml.contains("<title>") || xml.contains("<DIDL") { break }
            let next = unescape(xml)
            if next == xml { break }
            xml = next
        }
        guard xml.contains("<") else { return nil }
        let info = NowPlaying(
            title: unescape(tag(xml, "title") ?? ""),
            artist: unescape(tag(xml, "creator") ?? tag(xml, "artist") ?? ""),
            album: unescape(tag(xml, "album") ?? "")
        )
        return info.isEmpty ? nil : info
    }

    static func fetchLive(from uri: String) -> NowPlaying? {
        guard let components = URLComponents(string: uri),
              let host = components.host,
              let port = components.port,
              StreamFormat.isStreamPath(components.path),
              isLocal(host),
              let url = URL(string: "http://\(host):\(port)/now-playing") else { return nil }
        var request = URLRequest(url: url)
        request.timeoutInterval = 1
        request.cachePolicy = .reloadIgnoringLocalCacheData
        var body: String?
        let done = DispatchSemaphore(value: 0)
        URLSession.shared.dataTask(with: request) { data, response, _ in
            if let data, let response = response as? HTTPURLResponse, (200..<300).contains(response.statusCode) {
                body = String(data: data, encoding: .utf8)
            }
            done.signal()
        }.resume()
        _ = done.wait(timeout: .now() + 1.2)
        guard let body else { return nil }
        return parseListing(body)
    }

    private static func clean(_ text: String) -> String {
        let collapsed = text
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if collapsed == "missing value" { return "" }
        return String(collapsed.prefix(200))
    }

    private static func isLocal(_ host: String) -> Bool {
        if host == "localhost" { return true }
        let parts = host.split(separator: ".").compactMap { Int($0) }
        guard parts.count == 4, parts.allSatisfy({ (0...255).contains($0) }) else { return false }
        if parts[0] == 10 || parts[0] == 127 { return true }
        if parts[0] == 192 && parts[1] == 168 { return true }
        if parts[0] == 172 && (16...31).contains(parts[1]) { return true }
        if parts[0] == 169 && parts[1] == 254 { return true }
        return false
    }
}

struct FoundSpeaker: Identifiable, Hashable {
    var name: String
    var host: String
    var id: String { host }
}

/// Finds every visible Sonos room. Any one reachable speaker reports the whole
/// household in a single topology call, so known hosts are tried first and
/// Bonjour is only used to find a first speaker. Returns nil when nothing
/// answers, so callers can keep the list they already have.
func discoverSpeakers(known: [String]) -> [FoundSpeaker]? {
    for host in known {
        if let rooms = SonosSpeaker(host: host).rooms(), !rooms.isEmpty { return rooms }
    }
    guard let output = runDNSSD(["-B", "_sonos._tcp", "local."], seconds: 1.5) else { return nil }
    let names = output.split(separator: "\n").compactMap { line -> String? in
        guard line.contains("Add"), let range = line.range(of: "_sonos._tcp.") else { return nil }
        let name = String(line[range.upperBound...]).trimmingCharacters(in: .whitespaces)
        return name.isEmpty ? nil : name
    }
    var seen = Set<String>()
    for name in names.filter({ seen.insert($0).inserted }).prefix(3) {
        guard let text = runDNSSD(["-L", name, "_sonos._tcp", "local."], seconds: 1.5),
              let match = text.range(of: #"http://(\d+\.\d+\.\d+\.\d+):"#, options: .regularExpression) else { continue }
        let host = String(text[match].dropFirst("http://".count).dropLast())
        if let rooms = SonosSpeaker(host: host).rooms(), !rooms.isEmpty { return rooms }
    }
    return nil
}

/// Runs dns-sd for a bounded time and returns whatever it printed. Never waits
/// for the process to exit: dns-sd can ignore termination, and readDataToEndOfFile
/// would then block forever.
private func runDNSSD(_ arguments: [String], seconds: TimeInterval) -> String? {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/dns-sd")
    process.arguments = arguments
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = pipe
    guard (try? process.run()) != nil else { return nil }
    let collected = CollectedOutput()
    let handle = pipe.fileHandleForReading
    handle.readabilityHandler = { handle in
        let chunk = handle.availableData
        if chunk.isEmpty {
            handle.readabilityHandler = nil
        } else {
            collected.append(chunk)
        }
    }
    Thread.sleep(forTimeInterval: seconds)
    if process.isRunning {
        process.terminate()
        kill(process.processIdentifier, SIGKILL)
    }
    handle.readabilityHandler = nil
    return collected.text
}

private final class CollectedOutput: @unchecked Sendable {
    private var data = Data()
    private let lock = NSLock()

    func append(_ chunk: Data) {
        lock.lock()
        data.append(chunk)
        lock.unlock()
    }

    var text: String? {
        lock.lock()
        defer { lock.unlock() }
        return String(data: data, encoding: .utf8)
    }
}

func tag(_ xml: String, _ name: String) -> String? {
    guard let regex = try? NSRegularExpression(pattern: "<(?:\\w+:)?\(name)>(.*?)</(?:\\w+:)?\(name)>", options: [.dotMatchesLineSeparators]) else {
        return nil
    }
    let range = NSRange(xml.startIndex..., in: xml)
    guard let match = regex.firstMatch(in: xml, range: range), let slice = Range(match.range(at: 1), in: xml) else {
        return nil
    }
    let value = String(xml[slice]).trimmingCharacters(in: .whitespacesAndNewlines)
    return value.isEmpty ? nil : value
}

private func attribute(_ name: String, in text: String) -> String? {
    guard let start = text.range(of: "\(name)=\"") else { return nil }
    let rest = text[start.upperBound...]
    guard let end = rest.firstIndex(of: "\"") else { return nil }
    return String(rest[..<end])
}

private func xmlEscape(_ text: String) -> String {
    text.replacingOccurrences(of: "&", with: "&amp;")
        .replacingOccurrences(of: "<", with: "&lt;")
        .replacingOccurrences(of: ">", with: "&gt;")
        .replacingOccurrences(of: "\"", with: "&quot;")
}

private func unescape(_ text: String) -> String {
    text.replacingOccurrences(of: "&lt;", with: "<")
        .replacingOccurrences(of: "&gt;", with: ">")
        .replacingOccurrences(of: "&quot;", with: "\"")
        .replacingOccurrences(of: "&amp;", with: "&")
}
