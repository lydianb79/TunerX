import Accelerate
import Foundation

struct PitchResult {
    var rms: Float
    var frequency: Double?
    var clarity: Float
}

/// Two-stage high-precision fundamental estimator.
///
/// 1. **McLeod Pitch Method** (NSDF via FFT autocorrelation, key-maximum picking, parabolic
///    interpolation) gives a robust, octave-safe coarse estimate (≈ ±1 cent).
/// 2. **Phase-difference refinement**: a Hann-windowed single-bin DFT exactly at the estimate is
///    taken on two segments of the window spaced H samples apart. The phase advance between the
///    segments gives the frequency with very high resolution (typically < 0.01 cent on clean
///    guitar tones with the Precise/Ultra windows). Iterated twice, with an optional short-hop
///    first pass to widen the capture range for high notes.
/// If the fundamental is very weak relative to partials 2…4 (thin strings through small mics),
/// the strongest partial is measured and divided by its number.
final class PitchDetector {
    let size: Int
    let sampleRate: Double
    var minFrequency: Double = 25
    var maxFrequency: Double = 2000
    var gate: Float = 0.001
    var clarityThreshold: Float = 0.6

    private let half: Int
    private let log2n: vDSP_Length
    private let fft: FFTSetup
    private let x: UnsafeMutablePointer<Float>
    private let pad: UnsafeMutablePointer<Float>
    private let re: UnsafeMutablePointer<Float>
    private let im: UnsafeMutablePointer<Float>
    private let mags: UnsafeMutablePointer<Float>
    private let nsdf: UnsafeMutablePointer<Float>
    private var peaks: [(tau: Int, value: Float)] = []

    init(size: Int, sampleRate: Double) {
        precondition(size >= 1024 && size.nonzeroBitCount == 1, "window must be a power of two")
        self.size = size
        self.sampleRate = sampleRate
        half = size / 2
        log2n = vDSP_Length((2 * size).trailingZeroBitCount)
        fft = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2))!
        x = .allocate(capacity: size)
        pad = .allocate(capacity: 2 * size)
        re = .allocate(capacity: size)
        im = .allocate(capacity: size)
        mags = .allocate(capacity: size)
        nsdf = .allocate(capacity: size / 2 + 2)
        peaks.reserveCapacity(256)
    }

    deinit {
        vDSP_destroy_fftsetup(fft)
        x.deallocate(); pad.deallocate(); re.deallocate(); im.deallocate()
        mags.deallocate(); nsdf.deallocate()
    }

    func analyze(_ input: UnsafePointer<Float>) -> PitchResult {
        let n = vDSP_Length(size)

        // DC removal + energy
        var mean: Float = 0
        vDSP_meanv(input, 1, &mean, n)
        var neg = -mean
        vDSP_vsadd(input, 1, &neg, x, 1, n)
        var energy = 0.0
        for i in 0..<size { let v = Double(x[i]); energy += v * v }
        let rms = Float(sqrt(energy / Double(size)))
        guard rms > gate, energy > 0 else { return PitchResult(rms: rms, frequency: nil, clarity: 0) }

        // Autocorrelation r[τ] via zero-padded real FFT (Wiener–Khinchin)
        memcpy(pad, x, size * 4)
        memset(pad + size, 0, size * 4)
        var split = DSPSplitComplex(realp: re, imagp: im)
        pad.withMemoryRebound(to: DSPComplex.self, capacity: size) { vDSP_ctoz($0, 2, &split, 1, n) }
        vDSP_fft_zrip(fft, &split, 1, log2n, FFTDirection(FFT_FORWARD))
        let dc = re[0] * re[0], nyquist = im[0] * im[0]
        vDSP_zvmags(&split, 1, mags, 1, n)
        memcpy(re, mags, size * 4)
        vDSP_vclr(im, 1, n)
        re[0] = dc
        im[0] = nyquist
        vDSP_fft_zrip(fft, &split, 1, log2n, FFTDirection(FFT_INVERSE))
        pad.withMemoryRebound(to: DSPComplex.self, capacity: size) { vDSP_ztoc(&split, 1, $0, 2, n) }
        guard pad[0] > 0 else { return PitchResult(rms: rms, frequency: nil, clarity: 0) }
        let acfScale = energy / Double(pad[0])

        // NSDF n'(τ) = 2 r(τ) / m(τ), with m(τ) updated incrementally
        let maxTau = min(half - 2, Int(sampleRate / minFrequency) + 2)
        let minTau = max(2, Int(sampleRate / maxFrequency) - 1)
        guard maxTau > minTau + 2 else { return PitchResult(rms: rms, frequency: nil, clarity: 0) }
        var m = 2 * energy
        nsdf[0] = 1
        for tau in 1...(maxTau + 1) {
            let a = Double(x[tau - 1]), b = Double(x[size - tau])
            m -= a * a + b * b
            nsdf[tau] = m > 1e-20 ? Float(2 * Double(pad[tau]) * acfScale / m) : 0
        }

        // Key maxima: highest point of each positive lobe after the first zero crossing
        peaks.removeAll(keepingCapacity: true)
        var tau = 1
        while tau <= maxTau && nsdf[tau] > 0 { tau += 1 }
        var inLobe = false
        var bestTau = 0
        var bestVal: Float = 0
        while tau <= maxTau {
            let v = nsdf[tau]
            if v > 0 {
                if !inLobe { inLobe = true; bestTau = 0; bestVal = 0 }
                if v > bestVal { bestVal = v; bestTau = tau }
            } else if inLobe {
                inLobe = false
                if bestTau >= minTau { peaks.append((bestTau, bestVal)) }
            }
            tau += 1
        }
        if inLobe && bestTau >= minTau && bestTau < maxTau { peaks.append((bestTau, bestVal)) }
        guard let globalMax = peaks.map({ $0.value }).max(), globalMax > 0,
              let pick = peaks.first(where: { $0.value >= 0.9 * globalMax }) else {
            return PitchResult(rms: rms, frequency: nil, clarity: 0)
        }
        guard pick.value >= clarityThreshold else {
            return PitchResult(rms: rms, frequency: nil, clarity: pick.value)
        }

        let y0 = Double(nsdf[pick.tau - 1]), y1 = Double(nsdf[pick.tau]), y2 = Double(nsdf[pick.tau + 1])
        let denom = y0 - 2 * y1 + y2
        let tauF = Double(pick.tau) + (denom != 0 ? 0.5 * (y0 - y2) / denom : 0)
        let coarse = sampleRate / tauF
        let fine = refineFundamental(coarse)
        return PitchResult(rms: rms, frequency: fine, clarity: pick.value)
    }

    // MARK: Refinement

    private func refineFundamental(_ coarse: Double) -> Double {
        // Needs a few periods per segment for an unbiased phase measurement.
        guard coarse * Double(half) / sampleRate >= 4 else { return coarse }
        var f = coarse
        let shortL = min(half / 2, 2048)
        if f * Double(shortL) / sampleRate >= 8,
           let r = phaseRefine(f, start: size - 2 * shortL, length: shortL, hop: shortL) {
            f = r.freq
        }
        guard var fund = phaseRefine(f, start: 0, length: half, hop: half) else { return coarse }
        if let r = phaseRefine(fund.freq, start: 0, length: half, hop: half) { fund = r }

        var best = (mag: fund.mag, partial: 1, freq: fund.freq)
        for h in 2...4 where Double(h) * fund.freq < sampleRate * 0.45 {
            if let a = phaseRefine(Double(h) * fund.freq, start: 0, length: half, hop: half),
               let b = phaseRefine(a.freq, start: 0, length: half, hop: half),
               b.mag > best.mag {
                best = (b.mag, h, b.freq)
            }
        }
        var result = fund.freq
        if best.partial > 1 && fund.mag < 0.2 * best.mag { result = best.freq / Double(best.partial) }

        // Guard against phase-wrap mistakes: refinement must stay near the robust estimate.
        if !result.isFinite || abs(1200 * log2(result / coarse)) > 25 { return coarse }
        return result
    }

    /// Phase-vocoder style estimator around frequency `f` (Hz).
    private func phaseRefine(_ f: Double, start: Int, length L: Int, hop H: Int) -> (freq: Double, mag: Double)? {
        guard start >= 0, start + H + L <= size, L > 16 else { return nil }
        let w = 2 * Double.pi * f / sampleRate
        guard w > 0, w < Double.pi else { return nil }
        let cw = cos(w), sw = sin(w)
        let wh = 2 * Double.pi / Double(L - 1)
        let cwh = cos(wh), swh = sin(wh)
        var c = 1.0, s = 0.0          // carrier phasor e^{iwk}
        var hc = 1.0, hs = 0.0        // window phasor  e^{i·2πk/(L-1)}
        var ar = 0.0, ai = 0.0, br = 0.0, bi = 0.0
        let xa = x + start, xb = x + start + H
        for k in 0..<L {
            let win = 0.5 - 0.5 * hc
            let va = Double(xa[k]) * win
            let vb = Double(xb[k]) * win
            ar += va * c; ai -= va * s
            br += vb * c; bi -= vb * s
            let nc = c * cw - s * sw; s = s * cw + c * sw; c = nc
            let nh = hc * cwh - hs * swh; hs = hs * cwh + hc * swh; hc = nh
            if k & 1023 == 1023 {      // renormalise phasors against drift
                let g = 1 / sqrt(c * c + s * s); c *= g; s *= g
                let gh = 1 / sqrt(hc * hc + hs * hs); hc *= gh; hs *= gh
            }
        }
        let magA = sqrt(ar * ar + ai * ai), magB = sqrt(br * br + bi * bi)
        guard magA > 0, magB > 0 else { return nil }
        let dphi = atan2(bi * ar - br * ai, br * ar + bi * ai)     // arg(B · conj A)
        var d = dphi - w * Double(H)
        d -= 2 * Double.pi * (d / (2 * Double.pi)).rounded()
        let wTrue = w + d / Double(H)
        return (wTrue * sampleRate / (2 * Double.pi), 0.5 * (magA + magB))
    }
}
