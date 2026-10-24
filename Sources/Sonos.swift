import Foundation

struct SonosSpeaker {
    var host: String

    func prepare() throws -> Playback {
        let playback = Playback(
            uri: try tag(soap(path: "/MediaRenderer/AVTransport/Control", service: "AVTransport", action: "GetMediaInfo", body: "<InstanceID>0</InstanceID>"), "CurrentURI") ?? "",
            metadata: try tag(soap(path: "/MediaRenderer/AVTransport/Control", service: "AVTransport", action: "GetMediaInfo", body: "<InstanceID>0</InstanceID>"), "CurrentURIMetaData") ?? "",
            wasPlaying: (try tag(soap(path: "/MediaRenderer/AVTransport/Control", service: "AVTransport", action: "GetTransportInfo", body: "<InstanceID>0</InstanceID>"), "CurrentTransportState")) == "PLAYING"
        )
        let level = try tag(
            soap(path: "/MediaRenderer/RenderingControl/Control", service: "RenderingControl", action: "GetVolume", body: "<InstanceID>0</InstanceID><Channel>Master</Channel>"),
            "CurrentVolume"
        ) ?? "0"
        print("Volume is \(level).")
        if Int(level) == 0 {
            print("The speaker volume is 0, so turn it up if you hear nothing.")
        }
        return playback
    }

    func play(url: String) throws {
        let didl = """
        <DIDL-Lite xmlns:dc="http://purl.org/dc/elements/1.1/" xmlns:upnp="urn:schemas-upnp-org:metadata-1-0/upnp/" xmlns:r="urn:schemas-rinconnetworks-com:metadata-1-0/" xmlns="urn:schemas-upnp-org:metadata-1-0/DIDL-Lite/"><item id="1" parentID="-1" restricted="true"><dc:title>Sonos Pipe</dc:title><upnp:class>object.item.audioItem.audioBroadcast</upnp:class><desc id="cdudn" nameSpace="urn:schemas-rinconnetworks-com:metadata-1-0/">SA_RINCON65031_</desc><res protocolInfo="http-get:*:audio/mpeg:*">\(xmlEscape(url))</res></item></DIDL-Lite>
        """
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
        guard !playback.uri.isEmpty else { return }
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

struct FoundSpeaker: Identifiable, Hashable {
    var name: String
    var host: String
    var id: String { host }
}

func discoverSpeakers() -> [FoundSpeaker] {
    let fallback = [FoundSpeaker(name: "Kitchen", host: "192.168.4.21")]
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/dns-sd")
    process.arguments = ["-B", "_sonos._tcp", "local."]
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = pipe
    guard (try? process.run()) != nil else { return fallback }
    Thread.sleep(forTimeInterval: 2)
    process.terminate()
    let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    let names = output.split(separator: "\n").compactMap { line -> String? in
        guard line.contains("Add"), let range = line.range(of: "_sonos._tcp.") else { return nil }
        let name = String(line[range.upperBound...]).trimmingCharacters(in: .whitespaces)
        return name.isEmpty ? nil : name
    }
    var found: [FoundSpeaker] = []
    for name in names {
        let lookup = Process()
        lookup.executableURL = URL(fileURLWithPath: "/usr/bin/dns-sd")
        lookup.arguments = ["-L", name, "_sonos._tcp", "local."]
        let detail = Pipe()
        lookup.standardOutput = detail
        lookup.standardError = detail
        guard (try? lookup.run()) != nil else { continue }
        Thread.sleep(forTimeInterval: 1.5)
        lookup.terminate()
        let text = String(data: detail.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        guard let match = text.range(of: #"http://(\d+\.\d+\.\d+\.\d+):"#, options: .regularExpression) else { continue }
        let host = String(text[match].dropFirst("http://".count).dropLast())
        let room = name.split(separator: "@").last.map(String.init) ?? name
        if found.contains(where: { $0.host == host }) { continue }
        found.append(FoundSpeaker(name: room, host: host))
    }
    return found.isEmpty ? fallback : found
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
