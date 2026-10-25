import CoreAudio
import Foundation

final class Capture {
    private var tapDescription: CATapDescription?
    private var tapID: AudioObjectID = 0
    private var aggregateID: AudioObjectID = 0
    private var procID: AudioDeviceIOProcID?
    private var format = AudioStreamBasicDescription()
    private(set) var sampleRate: Double = 48_000
    private(set) var callbacks = 0
    private(set) var deliveredFrames = 0

    private var onSamples: (([Int16]) -> Void)?

    func open(objectIDs: [AudioObjectID], mute: Bool, onSamples: @escaping ([Int16]) -> Void) throws {
        self.onSamples = onSamples
        let description = CATapDescription(stereoMixdownOfProcesses: objectIDs)
        description.name = "Sonos Pipe"
        description.isPrivate = true
        description.muteBehavior = mute ? .muted : .unmuted
        let tapUUID = UUID()
        description.uuid = tapUUID
        tapDescription = description

        var createdTap: AudioObjectID = 0
        let tapStatus = AudioHardwareCreateProcessTap(description, &createdTap)
        guard tapStatus == noErr else {
            throw PipeError.audio("Could not tap that app", tapStatus)
        }
        tapID = createdTap

        let tapUID = stringProperty(tapID, kAudioTapPropertyUID) ?? tapUUID.uuidString
        format = streamFormat(tapID, selector: kAudioTapPropertyFormat) ?? AudioStreamBasicDescription()
        if format.mSampleRate > 0 { sampleRate = format.mSampleRate }

        let aggregateUID = UUID().uuidString
        let aggregate: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Sonos Pipe",
            kAudioAggregateDeviceUIDKey: aggregateUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceTapListKey: [
                [
                    kAudioSubTapUIDKey: tapUID,
                ],
            ],
        ]
        var createdAggregate: AudioObjectID = 0
        let aggregateStatus = AudioHardwareCreateAggregateDevice(aggregate as CFDictionary, &createdAggregate)
        guard aggregateStatus == noErr else {
            throw PipeError.audio("Could not open the audio tap", aggregateStatus)
        }
        aggregateID = createdAggregate

        if let deviceFormat = streamFormat(aggregateID, selector: kAudioDevicePropertyStreamFormat, scope: kAudioObjectPropertyScopeInput),
           deviceFormat.mSampleRate > 0 {
            format = deviceFormat
            sampleRate = deviceFormat.mSampleRate
        }
        if format.mChannelsPerFrame == 0 {
            format.mSampleRate = sampleRate
            format.mChannelsPerFrame = 2
            format.mBitsPerChannel = 32
            format.mFormatFlags = kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked
        }

        var newProc: AudioDeviceIOProcID?
        let procStatus = AudioDeviceCreateIOProcIDWithBlock(&newProc, aggregateID, nil) { [weak self] _, input, _, _, _ in
            guard let self else { return }
            self.callbacks += 1
            let samples = self.stereoInt16(from: input)
            self.deliveredFrames += samples.count / 2
            if !samples.isEmpty {
                self.onSamples?(samples)
            }
        }
        guard procStatus == noErr, let newProc else {
            throw PipeError.audio("Could not listen to the audio tap", procStatus)
        }
        procID = newProc
    }

    func begin() throws {
        guard let procID else { throw PipeError.message("Audio capture was not prepared.") }
        let startStatus = AudioDeviceStart(aggregateID, procID)
        guard startStatus == noErr else {
            throw PipeError.audio("Could not start the audio tap", startStatus)
        }
    }

    func stop() {
        if let procID, aggregateID != 0 {
            AudioDeviceStop(aggregateID, procID)
            AudioDeviceDestroyIOProcID(aggregateID, procID)
        }
        procID = nil
        if aggregateID != 0 {
            AudioHardwareDestroyAggregateDevice(aggregateID)
            aggregateID = 0
        }
        if tapID != 0 {
            AudioHardwareDestroyProcessTap(tapID)
            tapID = 0
        }
        tapDescription = nil
    }

    private func stereoInt16(from bufferList: UnsafePointer<AudioBufferList>) -> [Int16] {
        let buffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: bufferList))
        guard let first = buffers.first, let data = first.mData else { return [] }
        let channels = max(1, Int(format.mChannelsPerFrame == 0 ? 2 : format.mChannelsPerFrame))
        let nonInterleaved = format.mFormatFlags & kAudioFormatFlagIsNonInterleaved != 0
        let isFloat = format.mFormatFlags & kAudioFormatFlagIsFloat != 0
        let bytesPerSample = max(1, Int(format.mBitsPerChannel / 8))
        let frames = nonInterleaved
            ? Int(first.mDataByteSize) / bytesPerSample
            : Int(first.mDataByteSize) / (bytesPerSample * channels)
        guard frames > 0 else { return [] }

        var output = [Int16]()
        output.reserveCapacity(frames * 2)
        func store(_ left: Float, _ right: Float) {
            output.append(int16(left))
            output.append(int16(right))
        }

        if nonInterleaved {
            let left = data
            let right = buffers.count > 1 ? buffers[1].mData : nil
            for frame in 0..<frames {
                let l = sample(left, index: frame, isFloat: isFloat, bytes: bytesPerSample)
                let r = right.map { sample($0, index: frame, isFloat: isFloat, bytes: bytesPerSample) } ?? l
                store(l, r)
            }
        } else {
            for frame in 0..<frames {
                let l = sample(data, index: frame * channels, isFloat: isFloat, bytes: bytesPerSample)
                let r = channels > 1
                    ? sample(data, index: frame * channels + 1, isFloat: isFloat, bytes: bytesPerSample)
                    : l
                store(l, r)
            }
        }
        return output
    }

    private func sample(_ data: UnsafeMutableRawPointer, index: Int, isFloat: Bool, bytes: Int) -> Float {
        let pointer = data.advanced(by: index * bytes)
        if isFloat {
            return pointer.load(as: Float.self)
        }
        if bytes == 2 {
            return Float(pointer.load(as: Int16.self)) / 32767
        }
        if bytes == 4 {
            return Float(pointer.load(as: Int32.self)) / 2_147_483_648
        }
        return 0
    }

    private func int16(_ sample: Float) -> Int16 {
        let clipped = max(-1, min(1, sample))
        return Int16(clipped * 32767)
    }

    private func streamFormat(
        _ objectID: AudioObjectID,
        selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal
    ) -> AudioStreamBasicDescription? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: scope,
            mElement: kAudioObjectPropertyElementMain
        )
        var format = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        let status = AudioObjectGetPropertyData(objectID, &address, 0, nil, &size, &format)
        return status == noErr ? format : nil
    }

    private func stringProperty(_ objectID: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(objectID, &address, 0, nil, &size) == noErr, size > 0 else { return nil }
        var value: Unmanaged<CFString>?
        let status = AudioObjectGetPropertyData(objectID, &address, 0, nil, &size, &value)
        guard status == noErr, let value else { return nil }
        return value.takeRetainedValue() as String
    }
}

func defaultOutputSampleRate() -> Double {
    var address = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDefaultOutputDevice,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )
    var device = AudioObjectID(0)
    var size = UInt32(MemoryLayout<AudioObjectID>.size)
    guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device) == noErr else {
        return 48_000
    }
    address.mSelector = kAudioDevicePropertyNominalSampleRate
    var rate = Float64(0)
    size = UInt32(MemoryLayout<Float64>.size)
    guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &rate) == noErr, rate > 0 else {
        return 48_000
    }
    return rate
}

final class PCMQueue: @unchecked Sendable {
    private let lock = NSLock()
    private var samples: [Int16] = []

    func append(_ newSamples: [Int16]) {
        lock.lock()
        samples.append(contentsOf: newSamples)
        let limit = 48_000 * 2 * 2
        if samples.count > limit {
            samples.removeFirst(samples.count - limit)
        }
        lock.unlock()
    }

    func take() -> [Int16] {
        lock.lock()
        let taken = samples
        samples.removeAll(keepingCapacity: true)
        lock.unlock()
        return taken
    }
}

enum PipeError: Error, CustomStringConvertible, LocalizedError {
    case message(String)
    case audio(String, OSStatus)

    var description: String { errorDescription ?? "Something went wrong." }

    var errorDescription: String? {
        switch self {
        case .message(let text):
            return text
        case .audio(let text, let status):
            return "\(text) (\(statusText(status))). Allow Soyes under System Settings → Privacy & Security → Audio Capture if macOS asked for permission."
        }
    }
}

private func statusText(_ status: OSStatus) -> String {
    let bytes = [
        UInt8((status >> 24) & 0xFF),
        UInt8((status >> 16) & 0xFF),
        UInt8((status >> 8) & 0xFF),
        UInt8(status & 0xFF),
    ]
    if bytes.allSatisfy({ $0 >= 32 && $0 < 127 }) {
        return "'" + String(bytes: bytes, encoding: .ascii)! + "'"
    }
    return String(status)
}
