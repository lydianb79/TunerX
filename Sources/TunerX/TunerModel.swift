import AVFoundation
import Combine
import CoreAudio
import Foundation
import QuartzCore
import TXCore

enum AnalysisWindow: String, CaseIterable, Identifiable {
    case fast, balanced, precise, ultra
    var id: String { rawValue }

    var seconds: Double {
        switch self {
        case .fast: return 0.085
        case .balanced: return 0.17
        case .precise: return 0.34
        case .ultra: return 0.68
        }
    }

    var label: String {
        switch self {
        case .fast: return "Fast (~85 ms)"
        case .balanced: return "Balanced (~170 ms)"
        case .precise: return "Precise (~340 ms)"
        case .ultra: return "Ultra (~680 ms)"
        }
    }

    func frameCount(sampleRate: Double) -> Int {
        let target = max(2048, Int(sampleRate * seconds))
        var n = 1
        while n < target { n <<= 1 }
        return min(n, 131072)
    }
}

/// Numbers shown in the SwiftUI header (updated ~30×/s).
struct Readout: Equatable {
    var hasSignal = false
    var noteName = "–"
    var octave = ""
    var cents: Double = 0
    var frequency: Double = 0
    var target: Double = 0
    var clarity: Float = 0
    var levelDB: Float = -120
}

final class LiveReadout: ObservableObject {
    @Published var value = Readout()
}

/// Snapshot read by the Metal renderer every frame.
struct DisplaySnapshot {
    var hasSignal = false
    var midiCents: Double = 6900    // 100 × MIDI note number, fractional
    var midi = 69
    var cents: Double = 0
    var clarity: Float = 0
}

final class DisplayState {
    private let lock = NSLock()
    private var snapshot = DisplaySnapshot()
    func set(_ s: DisplaySnapshot) { lock.lock(); snapshot = s; lock.unlock() }
    func get() -> DisplaySnapshot { lock.lock(); defer { lock.unlock() }; return snapshot }
}

enum NoteNames {
    static let sharps = ["C", "C♯", "D", "D♯", "E", "F", "F♯", "G", "G♯", "A", "A♯", "B"]
    static func name(_ midi: Int) -> String { sharps[((midi % 12) + 12) % 12] }
    static func octave(_ midi: Int) -> Int { Int(floor(Double(midi) / 12)) - 1 }
    static func full(_ midi: Int) -> String { "\(name(midi))\(octave(midi))" }
}

private struct AnalysisParams {
    var a4 = 440.0
    var gate: Float = 0.001
    var smoothing = 0.5
    var refMidi = -1
}

final class TunerModel: ObservableObject {
    let engine = AudioEngine()
    let display = DisplayState()
    let live = LiveReadout()

    // Device lists
    @Published var inputDevices: [AudioDevice] = []
    @Published var outputDevices: [AudioDevice] = []
    @Published var inputChannelCount = 0
    @Published var availableBufferSizes: [UInt32] = []
    @Published var availableSampleRates: [Double] = []
    @Published var status = "Starting…"
    @Published var activeInfo = ""

    // Selection / settings
    @Published var inputDeviceID: AudioDeviceID = 0 {
        didSet { guard !suppress, oldValue != inputDeviceID else { return }; inputDeviceChanged() }
    }
    @Published var inputChannel: Int = 0 {
        didSet { guard !suppress, oldValue != inputChannel else { return }; scheduleRestart() }
    }
    @Published var outputDeviceID: AudioDeviceID = 0 {
        didSet { guard !suppress, oldValue != outputDeviceID else { return }; saveDefaults(); scheduleRestart() }
    }
    @Published var bufferSize: UInt32 = 256 {
        didSet { guard !suppress, oldValue != bufferSize else { return }; saveDefaults(); scheduleRestart() }
    }
    @Published var sampleRate: Double = 48000 {
        didSet { guard !suppress, oldValue != sampleRate else { return }; scheduleRestart() }
    }
    @Published var analysisWindow: AnalysisWindow = .precise {
        didSet { saveDefaults(); rebuildDetector() }
    }
    @Published var a4: Double = 440 { didSet { pushParams(); saveDefaults() } }
    @Published var smoothing: Double = 0.5 { didSet { pushParams(); saveDefaults() } }
    @Published var gateDB: Double = -60 { didSet { pushParams(); saveDefaults() } }
    @Published var refToneEnabled = false { didSet { engine.refToneEnabled = refToneEnabled } }
    @Published var refToneMidi: Int = -1 { didSet { pushParams(); updateFixedRefTone() } }
    @Published var refToneVolume: Double = 0.25 { didSet { engine.refToneGain = Float(refToneVolume * refToneVolume) } }
    @Published var monitorEnabled = false { didSet { engine.monitorEnabled = monitorEnabled } }
    @Published var monitorVolume: Double = 0.8 { didSet { engine.monitorGain = Float(monitorVolume) } }

    private var suppress = false
    private var restartPending = false
    private var micAuthorized = false
    private let defaults = UserDefaults.standard

    // Analysis thread state (only touched on analysisQueue)
    private let analysisQueue = DispatchQueue(label: "tunerx.analysis", qos: .userInteractive)
    private var timer: DispatchSourceTimer?
    private var detector: PitchDetector?
    private var analysisBuffer: UnsafeMutablePointer<Float>?
    private var analysisSize = 0
    private var history: [Double] = []
    private var smoothedMC: Double?
    private var pendingMC: Double?
    private var pendingCount = 0
    private var lastDetection: CFTimeInterval = 0
    private var levelDB: Float = -120
    private var tick = 0
    private var lastClarity: Float = 0
    private let paramsLock = NSLock()
    private var params = AnalysisParams()

    init() {
        loadDefaults()
        pushParams()
        engine.refToneGain = Float(refToneVolume * refToneVolume)
        engine.monitorGain = Float(monitorVolume)
        refreshDevices(initial: true)
        installDeviceListener()
        startAnalysisTimer()
        requestMicrophoneAndStart()
    }

    // MARK: Persistence

    private func loadDefaults() {
        suppress = true
        defer { suppress = false }
        if let w = defaults.string(forKey: "window").flatMap(AnalysisWindow.init(rawValue:)) { analysisWindow = w }
        if defaults.object(forKey: "a4") != nil { a4 = defaults.double(forKey: "a4") }
        if defaults.object(forKey: "smoothing") != nil { smoothing = defaults.double(forKey: "smoothing") }
        if defaults.object(forKey: "gateDB") != nil { gateDB = defaults.double(forKey: "gateDB") }
        if defaults.object(forKey: "bufferSize") != nil { bufferSize = UInt32(defaults.integer(forKey: "bufferSize")) }
    }

    private func saveDefaults() {
        guard !suppress else { return }
        defaults.set(analysisWindow.rawValue, forKey: "window")
        defaults.set(a4, forKey: "a4")
        defaults.set(smoothing, forKey: "smoothing")
        defaults.set(gateDB, forKey: "gateDB")
        defaults.set(Int(bufferSize), forKey: "bufferSize")
        defaults.set(inputDevices.first { $0.id == inputDeviceID }?.uid, forKey: "inputUID")
        defaults.set(outputDevices.first { $0.id == outputDeviceID }?.uid ?? "", forKey: "outputUID")
        defaults.set(inputChannel, forKey: "inputChannel")
    }

    // MARK: Devices

    private func installDeviceListener() {
        var addr = CoreAudioHelper.address(kAudioHardwarePropertyDevices)
        _ = AudioObjectAddPropertyListenerBlock(CoreAudioHelper.systemObject, &addr, DispatchQueue.main) { [weak self] _, _ in
            self?.refreshDevices(initial: false)
        }
    }

    func refreshDevices(initial: Bool) {
        let all = CoreAudioHelper.allDevices()
        inputDevices = all.filter { $0.inputChannels > 0 }
        outputDevices = all.filter { $0.outputChannels > 0 }

        var inputChanged = false
        suppress = true
        if initial {
            let uid = defaults.string(forKey: "inputUID")
            inputDeviceID = inputDevices.first { $0.uid == uid }?.id
                ?? CoreAudioHelper.defaultDevice(input: true) ?? inputDevices.first?.id ?? 0
            if let outUID = defaults.string(forKey: "outputUID") {
                outputDeviceID = outUID.isEmpty ? 0 : (outputDevices.first { $0.uid == outUID }?.id ?? 0)
            } else {
                outputDeviceID = CoreAudioHelper.defaultDevice(input: false) ?? 0
            }
            if defaults.object(forKey: "inputChannel") != nil { inputChannel = defaults.integer(forKey: "inputChannel") }
            inputChanged = true
        } else {
            if !inputDevices.contains(where: { $0.id == inputDeviceID }) {
                inputDeviceID = CoreAudioHelper.defaultDevice(input: true) ?? inputDevices.first?.id ?? 0
                inputChanged = true
            }
            if outputDeviceID != 0 && !outputDevices.contains(where: { $0.id == outputDeviceID }) {
                outputDeviceID = CoreAudioHelper.defaultDevice(input: false) ?? 0
                scheduleRestart()
            }
        }
        suppress = false
        if inputChanged { inputDeviceChanged(keepChannel: initial) }
    }

    private func inputDeviceChanged(keepChannel: Bool = false) {
        let id = inputDeviceID
        suppress = true
        inputChannelCount = CoreAudioHelper.channelCount(id, input: true)
        if !keepChannel || inputChannel >= inputChannelCount { inputChannel = 0 }
        availableBufferSizes = CoreAudioHelper.bufferSizes(id)
        if !availableBufferSizes.contains(bufferSize) {
            bufferSize = availableBufferSizes.min { abs(Int($0) - 256) < abs(Int($1) - 256) } ?? 256
        }
        availableSampleRates = CoreAudioHelper.availableSampleRates(id)
        sampleRate = CoreAudioHelper.nominalSampleRate(id) ?? availableSampleRates.first ?? 48000
        if !availableSampleRates.contains(sampleRate) { availableSampleRates.append(sampleRate); availableSampleRates.sort() }
        suppress = false
        saveDefaults()
        scheduleRestart()
    }

    // MARK: Audio engine

    private func requestMicrophoneAndStart() {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            micAuthorized = true
            scheduleRestart()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .audio) { granted in
                DispatchQueue.main.async {
                    self.micAuthorized = granted
                    if granted { self.scheduleRestart() } else { self.status = "Microphone access denied" }
                }
            }
        default:
            status = "Microphone access denied – enable TunerX in System Settings › Privacy & Security › Microphone"
        }
    }

    private func scheduleRestart() {
        guard !restartPending else { return }
        restartPending = true
        DispatchQueue.main.async { [weak self] in
            self?.restartPending = false
            self?.restartAudio()
        }
    }

    func restartAudio() {
        guard micAuthorized else { return }
        guard inputDeviceID != 0 else { status = "No input device"; return }
        let cfg = AudioEngine.Config(inputDevice: inputDeviceID, inputChannel: inputChannel,
                                     outputDevice: outputDeviceID, bufferSize: bufferSize, sampleRate: sampleRate)
        do {
            try engine.start(cfg)
            let sr = engine.sampleRate
            if abs(sr - sampleRate) > 0.5 {
                suppress = true; sampleRate = sr; suppress = false
            }
            let buf = engine.actualBufferSize
            activeInfo = String(format: "%.0f Hz · %u frames (%.2f ms) · input latency %.2f ms",
                                sr, buf, Double(buf) / sr * 1000, Double(engine.latencyFrames) / sr * 1000)
            status = "Running"
            rebuildDetector()
        } catch {
            status = error.localizedDescription
            activeInfo = ""
        }
    }

    // MARK: Analysis

    private func pushParams() {
        paramsLock.lock()
        params.a4 = a4
        params.gate = Float(pow(10, gateDB / 20))
        params.smoothing = smoothing
        params.refMidi = refToneMidi
        paramsLock.unlock()
    }

    private func readParams() -> AnalysisParams {
        paramsLock.lock(); defer { paramsLock.unlock() }
        return params
    }

    private func updateFixedRefTone() {
        if refToneMidi >= 0 { engine.refToneFrequency = a4 * pow(2, Double(refToneMidi - 69) / 12) }
    }

    private func rebuildDetector() {
        let sr = engine.sampleRate
        let n = analysisWindow.frameCount(sampleRate: sr)
        analysisQueue.async { [weak self] in
            guard let self else { return }
            self.analysisBuffer?.deallocate()
            self.analysisBuffer = .allocate(capacity: n)
            self.analysisSize = n
            self.detector = PitchDetector(size: n, sampleRate: sr)
            self.history.removeAll()
            self.smoothedMC = nil
        }
    }

    private func startAnalysisTimer() {
        let t = DispatchSource.makeTimerSource(queue: analysisQueue)
        t.schedule(deadline: .now(), repeating: .milliseconds(11), leeway: .milliseconds(2))
        t.setEventHandler { [weak self] in self?.analysisTick() }
        t.resume()
        timer = t
    }

    private func analysisTick() {
        let now = CACurrentMediaTime()
        let p = readParams()

        // Input level (peak hold with decay)
        let peak = engine.inputPeak
        engine.inputPeak = 0
        let peakDB = 20 * log10(max(peak, 1e-6))
        levelDB = max(peakDB, levelDB - 0.8)

        if let det = detector, let buf = analysisBuffer, engine.isRunning,
           tx_ring_copy_latest(engine.analysisRing, buf, UInt32(analysisSize)) == 1 {
            det.gate = p.gate
            let r = det.analyze(buf)
            lastClarity = r.clarity
            if let f = r.frequency, f > 0 { track(midiCents: 6900 + 1200 * log2(f / p.a4), now: now, smoothing: p.smoothing) }
        }

        let hasSignal = smoothedMC != nil && now - lastDetection < 0.6
        let mc = smoothedMC ?? 6900
        let midi = Int((mc / 100).rounded())
        let cents = mc - Double(midi) * 100
        display.set(DisplaySnapshot(hasSignal: hasSignal, midiCents: mc, midi: midi, cents: cents, clarity: lastClarity))

        if hasSignal {
            let freq = p.refMidi >= 0 ? p.a4 * pow(2, Double(p.refMidi - 69) / 12) : p.a4 * pow(2, Double(midi - 69) / 12)
            engine.refToneFrequency = freq
        }

        tick += 1
        if tick % 3 == 0 {
            let ro = Readout(hasSignal: hasSignal,
                             noteName: NoteNames.name(midi),
                             octave: "\(NoteNames.octave(midi))",
                             cents: cents,
                             frequency: p.a4 * pow(2, (mc - 6900) / 1200),
                             target: p.a4 * pow(2, Double(midi - 69) / 12),
                             clarity: lastClarity,
                             levelDB: levelDB)
            DispatchQueue.main.async { [weak self] in
                if self?.live.value != ro { self?.live.value = ro }
            }
        }
    }

    /// Outlier rejection, note-change hysteresis, median + exponential smoothing (in cents).
    private func track(midiCents mc: Double, now: CFTimeInterval, smoothing: Double) {
        let silentGap = now - lastDetection > 0.25
        lastDetection = now
        let historyLength = 3 + Int(smoothing * 10)
        let alpha = 1 - smoothing * 0.92

        if let s = smoothedMC, abs(mc - s) > 40, !silentGap {
            if let p = pendingMC, abs(mc - p) < 40 { pendingCount += 1 } else { pendingMC = mc; pendingCount = 1 }
            if pendingCount >= 3 {
                history = [mc]; smoothedMC = mc; pendingMC = nil; pendingCount = 0
            }
            return
        }
        pendingMC = nil
        pendingCount = 0
        if smoothedMC == nil || silentGap { history.removeAll(); smoothedMC = mc }
        history.append(mc)
        if history.count > historyLength { history.removeFirst(history.count - historyLength) }
        let sorted = history.sorted()
        let median = sorted.count % 2 == 1 ? sorted[sorted.count / 2]
                                           : 0.5 * (sorted[sorted.count / 2 - 1] + sorted[sorted.count / 2])
        smoothedMC = (smoothedMC ?? median) + alpha * (median - (smoothedMC ?? median))
    }
}
