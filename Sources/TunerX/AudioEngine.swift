import Accelerate
import AudioToolbox
import CoreAudio
import Foundation
import TXCore

struct AudioEngineError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

private func fourCC(_ status: OSStatus) -> String {
    let n = UInt32(bitPattern: status)
    let bytes = [UInt8((n >> 24) & 0xFF), UInt8((n >> 16) & 0xFF), UInt8((n >> 8) & 0xFF), UInt8(n & 0xFF)]
    guard bytes.allSatisfy({ $0 >= 32 && $0 < 127 }) else { return "\(status)" }
    return "'" + String(decoding: bytes, as: UTF8.self) + "'"
}

private func caCheck(_ status: OSStatus, _ what: String) throws {
    if status != noErr { throw AudioEngineError(message: "\(what) failed (\(fourCC(status)))") }
}

/// Low-latency CoreAudio engine built on two AUHAL units:
///  * an input unit bound to the selected input device (any channel of an audio interface)
///  * an optional output unit bound to the selected output device (reference tone + monitoring)
/// The input callback pushes mono samples into lock-free ring buffers that the analysis thread reads.
final class AudioEngine {
    struct Config: Equatable {
        var inputDevice: AudioDeviceID
        var inputChannel: Int            // -1 = mix all channels
        var outputDevice: AudioDeviceID  // 0 = none
        var bufferSize: UInt32
        var sampleRate: Double
    }

    static let ringCapacity: UInt32 = 1 << 19
    let analysisRing: OpaquePointer = tx_ring_create(AudioEngine.ringCapacity)!
    let monitorRing: OpaquePointer = tx_ring_create(1 << 15)!

    private(set) var sampleRate: Double = 48000
    private(set) var actualBufferSize: UInt32 = 0
    private(set) var inputChannelCount = 0
    private(set) var latencyFrames: UInt32 = 0
    private(set) var isRunning = false

    // Parameters shared with the realtime threads (plain scalars, written from main).
    var refToneEnabled = false
    var refToneFrequency: Double = 440
    var refToneGain: Float = 0.06
    var monitorEnabled = false
    var monitorGain: Float = 0.8
    /// Peak of the input since last read; reset by the reader.
    var inputPeak: Float = 0

    private let maxFrames = 8192
    private var inputUnit: AudioUnit?
    private var outputUnit: AudioUnit?
    private var inputBuffers: UnsafeMutableAudioBufferListPointer?
    private let mono = UnsafeMutablePointer<Float>.allocate(capacity: 8192)
    private let outScratch = UnsafeMutablePointer<Float>.allocate(capacity: 8192)
    private var selectedChannel = 0
    private var tonePhase: Double = 0
    private var toneGainSmoothed: Float = 0

    deinit {
        stop()
        tx_ring_destroy(analysisRing)
        tx_ring_destroy(monitorRing)
        mono.deallocate()
        outScratch.deallocate()
    }

    // MARK: Lifecycle

    func start(_ cfg: Config) throws {
        stop()
        let inDev = cfg.inputDevice
        guard inDev != 0 else { throw AudioEngineError(message: "No input device selected") }

        if cfg.sampleRate > 0 { CoreAudioHelper.setNominalSampleRate(inDev, cfg.sampleRate) }
        CoreAudioHelper.setBufferFrameSize(inDev, cfg.bufferSize)
        if cfg.outputDevice != 0 { CoreAudioHelper.setBufferFrameSize(cfg.outputDevice, cfg.bufferSize) }

        do {
            try startInput(device: inDev, channel: cfg.inputChannel)
            if cfg.outputDevice != 0, CoreAudioHelper.channelCount(cfg.outputDevice, input: false) > 0 {
                try startOutput(device: cfg.outputDevice)
            }
        } catch {
            stop()
            throw error
        }

        // Re-apply: the AUHAL may negotiate its own size while initializing.
        CoreAudioHelper.setBufferFrameSize(inDev, cfg.bufferSize)
        actualBufferSize = CoreAudioHelper.bufferFrameSize(inDev) ?? cfg.bufferSize
        latencyFrames = CoreAudioHelper.inputLatencyFrames(inDev) + actualBufferSize
        isRunning = true
    }

    func stop() {
        if let u = inputUnit {
            AudioOutputUnitStop(u); AudioUnitUninitialize(u); AudioComponentInstanceDispose(u)
        }
        if let u = outputUnit {
            AudioOutputUnitStop(u); AudioUnitUninitialize(u); AudioComponentInstanceDispose(u)
        }
        inputUnit = nil
        outputUnit = nil
        if let abl = inputBuffers {
            for b in abl { free(b.mData) }
            free(abl.unsafeMutablePointer)
        }
        inputBuffers = nil
        isRunning = false
    }

    // MARK: Unit setup

    private func makeHALUnit() throws -> AudioUnit {
        var desc = AudioComponentDescription(componentType: kAudioUnitType_Output,
                                             componentSubType: kAudioUnitSubType_HALOutput,
                                             componentManufacturer: kAudioUnitManufacturer_Apple,
                                             componentFlags: 0, componentFlagsMask: 0)
        guard let comp = AudioComponentFindNext(nil, &desc) else {
            throw AudioEngineError(message: "AUHAL component not found")
        }
        var unit: AudioUnit?
        try caCheck(AudioComponentInstanceNew(comp, &unit), "Create AUHAL")
        guard let u = unit else { throw AudioEngineError(message: "AUHAL instance is nil") }
        return u
    }

    private func setProp<T>(_ unit: AudioUnit, _ prop: AudioUnitPropertyID, _ scope: AudioUnitScope,
                            _ element: AudioUnitElement, _ value: T, _ what: String) throws {
        var v = value
        try caCheck(AudioUnitSetProperty(unit, prop, scope, element, &v, UInt32(MemoryLayout<T>.size)), what)
    }

    private func floatFormat(rate: Double, channels: Int) -> AudioStreamBasicDescription {
        AudioStreamBasicDescription(mSampleRate: rate,
                                    mFormatID: kAudioFormatLinearPCM,
                                    mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked | kAudioFormatFlagIsNonInterleaved,
                                    mBytesPerPacket: 4, mFramesPerPacket: 1, mBytesPerFrame: 4,
                                    mChannelsPerFrame: UInt32(channels), mBitsPerChannel: 32, mReserved: 0)
    }

    private func startInput(device: AudioDeviceID, channel: Int) throws {
        let unit = try makeHALUnit()
        inputUnit = unit
        try setProp(unit, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Input, 1, UInt32(1), "Enable input")
        try setProp(unit, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Output, 0, UInt32(0), "Disable output")
        try setProp(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, device, "Select input device")

        var hw = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        try caCheck(AudioUnitGetProperty(unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, 1, &hw, &size),
                    "Read input format")
        let channels = max(1, Int(hw.mChannelsPerFrame))
        let rate = hw.mSampleRate > 0 ? hw.mSampleRate : (CoreAudioHelper.nominalSampleRate(device) ?? 48000)

        try setProp(unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output, 1,
                    floatFormat(rate: rate, channels: channels), "Set input client format")
        try setProp(unit, kAudioUnitProperty_MaximumFramesPerSlice, kAudioUnitScope_Global, 0,
                    UInt32(maxFrames), "Set max frames")
        let cb = AURenderCallbackStruct(inputProc: txInputProc,
                                        inputProcRefCon: Unmanaged.passUnretained(self).toOpaque())
        try setProp(unit, kAudioOutputUnitProperty_SetInputCallback, kAudioUnitScope_Global, 0, cb, "Set input callback")

        let abl = AudioBufferList.allocate(maximumBuffers: channels)
        for i in 0..<channels {
            abl[i] = AudioBuffer(mNumberChannels: 1, mDataByteSize: UInt32(maxFrames * 4),
                                 mData: calloc(maxFrames, 4))
        }
        inputBuffers = abl
        inputChannelCount = channels
        selectedChannel = channel < channels ? channel : -1
        sampleRate = rate
        tx_ring_reset(analysisRing)
        tx_ring_reset(monitorRing)

        try caCheck(AudioUnitInitialize(unit), "Initialize input unit")
        try caCheck(AudioOutputUnitStart(unit), "Start input unit")
    }

    private func startOutput(device: AudioDeviceID) throws {
        let unit = try makeHALUnit()
        outputUnit = unit
        try setProp(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, device, "Select output device")
        let outChannels = min(2, max(1, CoreAudioHelper.channelCount(device, input: false)))
        // Client format runs at the *input* rate; the AUHAL converts to the output device rate.
        try setProp(unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, 0,
                    floatFormat(rate: sampleRate, channels: outChannels), "Set output client format")
        try setProp(unit, kAudioUnitProperty_MaximumFramesPerSlice, kAudioUnitScope_Global, 0,
                    UInt32(maxFrames), "Set max frames (out)")
        let cb = AURenderCallbackStruct(inputProc: txOutputProc,
                                        inputProcRefCon: Unmanaged.passUnretained(self).toOpaque())
        try setProp(unit, kAudioUnitProperty_SetRenderCallback, kAudioUnitScope_Input, 0, cb, "Set render callback")
        try caCheck(AudioUnitInitialize(unit), "Initialize output unit")
        try caCheck(AudioOutputUnitStart(unit), "Start output unit")
    }

    // MARK: Realtime callbacks

    fileprivate func renderInput(_ flags: UnsafeMutablePointer<AudioUnitRenderActionFlags>,
                                 _ ts: UnsafePointer<AudioTimeStamp>, _ frames: UInt32) -> OSStatus {
        guard let unit = inputUnit, let abl = inputBuffers else { return noErr }
        let n = Int(min(frames, UInt32(maxFrames)))
        for i in 0..<abl.count { abl[i].mDataByteSize = UInt32(n * 4) }
        let status = AudioUnitRender(unit, flags, ts, 1, UInt32(n), abl.unsafeMutablePointer)
        guard status == noErr else { return status }

        let count = abl.count
        let ch = selectedChannel
        if ch >= 0 && ch < count, let src = abl[ch].mData {
            memcpy(mono, src, n * 4)
        } else {
            vDSP_vclr(mono, 1, vDSP_Length(n))
            for i in 0..<count {
                if let src = abl[i].mData?.assumingMemoryBound(to: Float.self) {
                    vDSP_vadd(mono, 1, src, 1, mono, 1, vDSP_Length(n))
                }
            }
            var s = 1 / Float(max(1, count))
            vDSP_vsmul(mono, 1, &s, mono, 1, vDSP_Length(n))
        }
        var peak: Float = 0
        vDSP_maxmgv(mono, 1, &peak, vDSP_Length(n))
        if peak > inputPeak { inputPeak = peak }

        tx_ring_write(analysisRing, mono, UInt32(n))
        if monitorEnabled { tx_ring_write(monitorRing, mono, UInt32(n)) }
        return noErr
    }

    fileprivate func renderOutput(_ frames: UInt32, _ ioData: UnsafeMutablePointer<AudioBufferList>?) -> OSStatus {
        guard let ioData else { return noErr }
        let abl = UnsafeMutableAudioBufferListPointer(ioData)
        let n = Int(frames)
        guard n <= maxFrames else {
            for b in abl { if let d = b.mData { memset(d, 0, Int(b.mDataByteSize)) } }
            return noErr
        }

        var got = 0
        if monitorEnabled {
            tx_ring_trim(monitorRing, UInt32(n * 2 + 64))   // keep monitoring latency bounded
            got = Int(tx_ring_read(monitorRing, outScratch, UInt32(n)))
            var g = monitorGain
            vDSP_vsmul(outScratch, 1, &g, outScratch, 1, vDSP_Length(got))
        }
        if got < n { vDSP_vclr(outScratch + got, 1, vDSP_Length(n - got)) }

        let target: Float = refToneEnabled ? refToneGain : 0
        if target > 0 || toneGainSmoothed > 1e-6 {
            let inc = 2 * Double.pi * refToneFrequency / sampleRate
            for i in 0..<n {
                toneGainSmoothed += (target - toneGainSmoothed) * 0.002
                outScratch[i] += Float(sin(tonePhase)) * toneGainSmoothed
                tonePhase += inc
                if tonePhase >= 2 * Double.pi { tonePhase -= 2 * Double.pi }
            }
        } else {
            toneGainSmoothed = 0
        }
        for b in abl {
            if let d = b.mData { memcpy(d, outScratch, min(Int(b.mDataByteSize), n * 4)) }
        }
        return noErr
    }
}

private func txInputProc(_ refCon: UnsafeMutableRawPointer,
                         _ flags: UnsafeMutablePointer<AudioUnitRenderActionFlags>,
                         _ ts: UnsafePointer<AudioTimeStamp>,
                         _ bus: UInt32, _ frames: UInt32,
                         _ data: UnsafeMutablePointer<AudioBufferList>?) -> OSStatus {
    Unmanaged<AudioEngine>.fromOpaque(refCon).takeUnretainedValue().renderInput(flags, ts, frames)
}

private func txOutputProc(_ refCon: UnsafeMutableRawPointer,
                          _ flags: UnsafeMutablePointer<AudioUnitRenderActionFlags>,
                          _ ts: UnsafePointer<AudioTimeStamp>,
                          _ bus: UInt32, _ frames: UInt32,
                          _ data: UnsafeMutablePointer<AudioBufferList>?) -> OSStatus {
    Unmanaged<AudioEngine>.fromOpaque(refCon).takeUnretainedValue().renderOutput(frames, data)
}
