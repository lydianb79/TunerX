import Foundation

/// Mains-hum suppression setting.
enum HumFilterMode: String, CaseIterable, Identifiable {
    case auto, hz50, hz60, off
    var id: String { rawValue }

    var label: String {
        switch self {
        case .auto: return "Auto"
        case .hz50: return "50 Hz"
        case .hz60: return "60 Hz"
        case .off: return "Off"
        }
    }

    /// Mains frequency of the user's region, used as the starting guess for Auto.
    static var regionalMains: Double {
        let sixty: Set<String> = ["US", "CA", "MX", "BR", "CO", "VE", "EC", "PE", "BO", "CR", "GT", "HN",
                                  "NI", "PA", "SV", "DO", "PR", "CU", "HT", "JM", "TT", "BS", "BZ", "GU",
                                  "KR", "TW", "PH", "SA", "LR", "AS", "VI", "MP", "FM", "MH", "PW"]
        return sixty.contains(Locale.current.region?.identifier ?? "") ? 60 : 50
    }
}

/// Cascade of very narrow notch filters at the mains frequency and its harmonics (1…8),
/// run in double precision. Each notch is ~1.5 Hz wide, so notes next to a hum harmonic
/// (G1 = 49 Hz, G2 = 98 Hz, D3 = 146.8 Hz …) keep their level and, being steady sinusoids,
/// their frequency. Only the analysis signal is filtered, never the monitor output.
final class HumFilter {
    private struct Section {
        var b0, b1, b2, a1, a2: Double
        var z1 = 0.0, z2 = 0.0
    }
    private var sections: [Section] = []
    private(set) var mains: Double = 0
    private var sampleRate: Double = 0

    /// Rebuilds the cascade (and clears its state) when the mains or sample rate changes. 0 = bypass.
    func configure(mains: Double, sampleRate: Double, harmonics: Int = 8, bandwidth: Double = 1.5) {
        guard mains != self.mains || sampleRate != self.sampleRate else { return }
        self.mains = mains
        self.sampleRate = sampleRate
        sections.removeAll()
        guard mains > 0 else { return }
        for k in 1...harmonics {
            let f = mains * Double(k)
            if f > 0.45 * sampleRate { break }
            let w0 = 2 * Double.pi * f / sampleRate
            let alpha = sin(w0) * bandwidth / (2 * f)          // Q = f / bandwidth
            let a0 = 1 + alpha
            let c = -2 * cos(w0)
            sections.append(Section(b0: 1 / a0, b1: c / a0, b2: 1 / a0, a1: c / a0, a2: (1 - alpha) / a0))
        }
    }

    func reset() {
        for i in sections.indices { sections[i].z1 = 0; sections[i].z2 = 0 }
    }

    /// In-place, transposed direct form II.
    func process(_ buf: UnsafeMutablePointer<Float>, count: Int) {
        guard !sections.isEmpty else { return }
        for i in 0..<count {
            var v = Double(buf[i])
            for s in sections.indices {
                let y = sections[s].b0 * v + sections[s].z1
                sections[s].z1 = sections[s].b1 * v - sections[s].a1 * y + sections[s].z2
                sections[s].z2 = sections[s].b2 * v - sections[s].a2 * y
                v = y
            }
            buf[i] = Float(v)
        }
    }
}

/// Measures hum at 50/100/150 Hz versus 60/120/180 Hz by narrow-band demodulation
/// (time constant 0.5 s) of the unfiltered input. Decisions are only taken while no note is
/// sounding, and need three agreeing one-second readings, so playing never flips the setting.
final class MainsDetector {
    private let freqs: [Double] = [50, 100, 150, 60, 120, 180]
    private var phase = [Double](repeating: 0, count: 6)
    private var re = [Double](repeating: 0, count: 6)
    private var im = [Double](repeating: 0, count: 6)
    private var sampleRate: Double = 48000
    private var samplesSinceDecision = 0
    private var votes = 0
    private var candidate: Double = 0
    private(set) var detected: Double = 0     // 0 = unknown

    func configure(sampleRate: Double) {
        self.sampleRate = sampleRate
        for i in 0..<6 { phase[i] = 0; re[i] = 0; im[i] = 0 }
        samplesSinceDecision = 0
    }

    func process(_ buf: UnsafePointer<Float>, count: Int, quiet: Bool) {
        let alpha = 1 - exp(-1 / (0.5 * sampleRate))
        for j in 0..<6 {
            let inc = 2 * Double.pi * freqs[j] / sampleRate
            var p = phase[j], r = re[j], q = im[j]
            for i in 0..<count {
                let v = Double(buf[i])
                r += alpha * (v * cos(p) - r)
                q += alpha * (-v * sin(p) - q)
                p += inc
                if p > 2 * Double.pi { p -= 2 * Double.pi }
            }
            phase[j] = p; re[j] = r; im[j] = q
        }
        samplesSinceDecision += count
        guard samplesSinceDecision >= Int(sampleRate) else { return }
        samplesSinceDecision = 0
        guard quiet else { votes = 0; return }
        var p50 = 0.0, p60 = 0.0
        for j in 0..<3 { p50 += hypot(re[j], im[j]) }
        for j in 3..<6 { p60 += hypot(re[j], im[j]) }
        let winner: Double
        if p50 > 3 * p60 && p50 > 3e-5 { winner = 50 } else if p60 > 3 * p50 && p60 > 3e-5 { winner = 60 } else { votes = 0; return }
        if winner == candidate { votes += 1 } else { candidate = winner; votes = 1 }
        if votes >= 3 { detected = winner }
    }
}

/// Contiguous view onto the most recent filtered samples (single-threaded, analysis queue only).
final class SampleHistory {
    private let buffer: UnsafeMutablePointer<Float>
    let capacity: Int
    private var writeIndex = 0
    private(set) var filled = 0

    init(capacity: Int) {
        self.capacity = capacity
        buffer = .allocate(capacity: capacity)
        buffer.initialize(repeating: 0, count: capacity)
    }

    deinit { buffer.deallocate() }

    func reset() { writeIndex = 0; filled = 0 }

    func append(_ src: UnsafePointer<Float>, count: Int) {
        var src = src
        var n = count
        if n > capacity { src += n - capacity; n = capacity }
        let first = min(n, capacity - writeIndex)
        (buffer + writeIndex).update(from: src, count: first)
        if n > first { buffer.update(from: src + first, count: n - first) }
        writeIndex = (writeIndex + n) % capacity
        filled = min(capacity, filled + n)
    }

    /// Copies the latest `n` samples into `dst`. Returns false if not enough data yet.
    func copyLatest(_ n: Int, into dst: UnsafeMutablePointer<Float>) -> Bool {
        guard n <= filled, n <= capacity else { return false }
        let start = (writeIndex - n + capacity) % capacity
        let first = min(n, capacity - start)
        dst.update(from: buffer + start, count: first)
        if n > first { (dst + first).update(from: buffer, count: n - first) }
        return true
    }
}
