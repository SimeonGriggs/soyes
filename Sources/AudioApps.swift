import AppKit
import CoreAudio
import Darwin

struct AudioApp: Identifiable {
    var id: pid_t { ownerPID }
    var name: String
    var bundleID: String
    var ownerPID: pid_t
    var objectIDs: [AudioObjectID]
    var outputRunning: Bool
}

enum AudioApps {
    static func list() -> [AudioApp] {
        let processes = processObjects()
        var groups: [pid_t: AudioApp] = [:]
        for process in processes {
            let owner = owner(of: process.pid)
            var group = groups[owner.pid] ?? AudioApp(
                name: owner.name,
                bundleID: owner.bundleID,
                ownerPID: owner.pid,
                objectIDs: [],
                outputRunning: false
            )
            group.objectIDs.append(process.objectID)
            group.outputRunning = group.outputRunning || process.outputRunning
            if group.name.hasPrefix("pid "), !owner.name.hasPrefix("pid ") {
                group.name = owner.name
                group.bundleID = owner.bundleID
            }
            groups[owner.pid] = group
        }
        return groups.values.sorted {
            if $0.outputRunning != $1.outputRunning { return $0.outputRunning && !$1.outputRunning }
            return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
    }

    static func match(_ query: String, in apps: [AudioApp]) -> [AudioApp] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let exact = apps.filter {
            $0.name.caseInsensitiveCompare(needle) == .orderedSame
                || $0.bundleID.caseInsensitiveCompare(needle) == .orderedSame
        }
        if !exact.isEmpty { return exact }
        return apps.filter {
            $0.name.localizedCaseInsensitiveContains(needle)
                || $0.bundleID.localizedCaseInsensitiveContains(needle)
        }
    }

    private struct ProcessObject {
        var objectID: AudioObjectID
        var pid: pid_t
        var outputRunning: Bool
    }

    private static func processObjects() -> [ProcessObject] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyProcessObjectList,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        let system = AudioObjectID(kAudioObjectSystemObject)
        guard AudioObjectGetPropertyDataSize(system, &address, 0, nil, &size) == noErr,
              size > 0 else { return [] }
        let count = Int(size) / MemoryLayout<AudioObjectID>.size
        var ids = [AudioObjectID](repeating: 0, count: count)
        guard AudioObjectGetPropertyData(system, &address, 0, nil, &size, &ids) == noErr else {
            return []
        }
        return ids.compactMap { objectID in
            guard let pid = integerProperty(objectID, kAudioProcessPropertyPID, as: pid_t.self) else { return nil }
            let running = integerProperty(objectID, kAudioProcessPropertyIsRunningOutput, as: UInt32.self) ?? 0
            return ProcessObject(objectID: objectID, pid: pid, outputRunning: running != 0)
        }
    }

    private static func owner(of pid: pid_t) -> (name: String, bundleID: String, pid: pid_t) {
        var current = pid
        var fallback: (String, String, pid_t)?
        for _ in 0..<8 {
            if let app = NSRunningApplication(processIdentifier: current) {
                let name = app.localizedName ?? app.bundleIdentifier ?? "pid \(current)"
                let bundleID = app.bundleIdentifier ?? ""
                if app.activationPolicy == .regular {
                    return (name, bundleID, current)
                }
                if fallback == nil { fallback = (name, bundleID, current) }
            }
            let parent = parentPID(current)
            if parent <= 1 || parent == current { break }
            current = parent
        }
        return fallback ?? ("pid \(pid)", "", pid)
    }

    private static func parentPID(_ pid: pid_t) -> pid_t {
        var info = proc_bsdinfo()
        let size = proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, Int32(MemoryLayout<proc_bsdinfo>.stride))
        guard size == MemoryLayout<proc_bsdinfo>.stride else { return 0 }
        return pid_t(info.pbi_ppid)
    }

    private static func integerProperty<T: FixedWidthInteger>(
        _ objectID: AudioObjectID,
        _ selector: AudioObjectPropertySelector,
        as type: T.Type
    ) -> T? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value = T.zero
        var size = UInt32(MemoryLayout<T>.size)
        let status = withUnsafeMutablePointer(to: &value) {
            AudioObjectGetPropertyData(objectID, &address, 0, nil, &size, $0)
        }
        return status == noErr ? value : nil
    }
}
