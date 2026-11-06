import CoreAudio
import Foundation

/// A CoreAudio device (built-in, USB/Thunderbolt audio interface, aggregate …).
struct AudioDevice: Identifiable, Hashable {
    let id: AudioDeviceID
    let uid: String
    let name: String
    let inputChannels: Int
    let outputChannels: Int
}

/// Thin, typed wrappers around the CoreAudio HAL property API.
enum CoreAudioHelper {
    static let systemObject = AudioObjectID(kAudioObjectSystemObject)

    static func address(_ selector: AudioObjectPropertySelector,
                        _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }

    static func get<T>(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector,
                       scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal, initial: T) -> T? {
        var addr = address(selector, scope)
        var value = initial
        var size = UInt32(MemoryLayout<T>.size)
        let status = AudioObjectGetPropertyData(object, &addr, 0, nil, &size, &value)
        return status == noErr ? value : nil
    }

    @discardableResult
    static func set<T>(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector,
                       scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal, value: T) -> OSStatus {
        var addr = address(selector, scope)
        var v = value
        return AudioObjectSetPropertyData(object, &addr, 0, nil, UInt32(MemoryLayout<T>.size), &v)
    }

    static func string(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
        var addr = address(selector)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let status = withUnsafeMutablePointer(to: &value) { ptr in
            AudioObjectGetPropertyData(object, &addr, 0, nil, &size, ptr)
        }
        guard status == noErr, let v = value else { return nil }
        return v.takeRetainedValue() as String
    }

    static func deviceIDs() -> [AudioDeviceID] {
        var addr = address(kAudioHardwarePropertyDevices)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(systemObject, &addr, 0, nil, &size) == noErr, size > 0 else { return [] }
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(systemObject, &addr, 0, nil, &size, &ids) == noErr else { return [] }
        return ids
    }

    static func channelCount(_ id: AudioDeviceID, input: Bool) -> Int {
        var addr = address(kAudioDevicePropertyStreamConfiguration,
                           input ? kAudioDevicePropertyScopeInput : kAudioDevicePropertyScopeOutput)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &addr, 0, nil, &size) == noErr, size > 0 else { return 0 }
        let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: 16)
        defer { raw.deallocate() }
        guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, raw) == noErr else { return 0 }
        let list = UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self))
        return list.reduce(0) { $0 + Int($1.mNumberChannels) }
    }

    static func allDevices() -> [AudioDevice] {
        deviceIDs().map { id in
            AudioDevice(id: id,
                        uid: string(id, kAudioDevicePropertyDeviceUID) ?? "\(id)",
                        name: string(id, kAudioObjectPropertyName) ?? "Device \(id)",
                        inputChannels: channelCount(id, input: true),
                        outputChannels: channelCount(id, input: false))
        }
    }

    static func defaultDevice(input: Bool) -> AudioDeviceID? {
        let sel = input ? kAudioHardwarePropertyDefaultInputDevice : kAudioHardwarePropertyDefaultOutputDevice
        guard let id = get(systemObject, sel, initial: AudioDeviceID(0)), id != 0 else { return nil }
        return id
    }

    // MARK: Buffer size

    static func bufferFrameSize(_ id: AudioDeviceID) -> UInt32? {
        get(id, kAudioDevicePropertyBufferFrameSize, initial: UInt32(0))
    }

    static func bufferFrameSizeRange(_ id: AudioDeviceID) -> ClosedRange<UInt32>? {
        guard let r = get(id, kAudioDevicePropertyBufferFrameSizeRange, initial: AudioValueRange()),
              r.mMaximum >= r.mMinimum, r.mMaximum > 0 else { return nil }
        return UInt32(r.mMinimum)...UInt32(r.mMaximum)
    }

    /// Selectable buffer sizes for the device (powers of two inside the HAL range).
    static func bufferSizes(_ id: AudioDeviceID) -> [UInt32] {
        let candidates: [UInt32] = [16, 32, 64, 128, 256, 512, 1024, 2048, 4096]
        guard let range = bufferFrameSizeRange(id) else { return [64, 128, 256, 512, 1024] }
        let list = candidates.filter { range.contains($0) }
        return list.isEmpty ? [range.lowerBound] : list
    }

    @discardableResult
    static func setBufferFrameSize(_ id: AudioDeviceID, _ frames: UInt32) -> OSStatus {
        set(id, kAudioDevicePropertyBufferFrameSize, value: frames)
    }

    // MARK: Sample rate

    static func nominalSampleRate(_ id: AudioDeviceID) -> Double? {
        get(id, kAudioDevicePropertyNominalSampleRate, initial: Float64(0)).flatMap { $0 > 0 ? $0 : nil }
    }

    static func availableSampleRates(_ id: AudioDeviceID) -> [Double] {
        var addr = address(kAudioDevicePropertyAvailableNominalSampleRates)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &addr, 0, nil, &size) == noErr, size > 0 else {
            return nominalSampleRate(id).map { [$0] } ?? []
        }
        var ranges = [AudioValueRange](repeating: AudioValueRange(),
                                       count: Int(size) / MemoryLayout<AudioValueRange>.size)
        guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &ranges) == noErr else { return [] }
        let common: [Double] = [44100, 48000, 88200, 96000, 176400, 192000]
        var result = Set<Double>()
        for r in ranges {
            if r.mMinimum == r.mMaximum { result.insert(r.mMinimum) }
            else { common.filter { $0 >= r.mMinimum && $0 <= r.mMaximum }.forEach { result.insert($0) } }
        }
        return result.sorted()
    }

    /// Changes the device's nominal rate and waits (briefly) until the HAL reports it.
    static func setNominalSampleRate(_ id: AudioDeviceID, _ rate: Double) {
        guard let current = nominalSampleRate(id), abs(current - rate) > 0.5 else { return }
        set(id, kAudioDevicePropertyNominalSampleRate, value: Float64(rate))
        for _ in 0..<50 {
            if let now = nominalSampleRate(id), abs(now - rate) < 0.5 { return }
            usleep(10_000)
        }
    }

    // MARK: Latency

    /// Total input-side latency in frames (device latency + safety offset), excluding the IO buffer.
    static func inputLatencyFrames(_ id: AudioDeviceID) -> UInt32 {
        let lat = get(id, kAudioDevicePropertyLatency, scope: kAudioDevicePropertyScopeInput, initial: UInt32(0)) ?? 0
        let safety = get(id, kAudioDevicePropertySafetyOffset, scope: kAudioDevicePropertyScopeInput, initial: UInt32(0)) ?? 0
        return lat + safety
    }
}
