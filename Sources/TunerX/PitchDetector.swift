import Accelerate
import Foundation

struct PitchResult {
    var rms: Float
    var frequency: Double?
    var clarity: Float
}

/// High-precision fundamental estimator for plucked strings.
///
/// 1. **McLeod Pitch Method** (NSDF via FFT autocorrelation, key-maximum picking, parabolic
///    interpolation) gives a robust, octave-safe coarse estimate.
/// 2. **Phase-vocoder refinement**: the window is split into two halves, each Hann-windowed and
///    zero-padded 2×. For any partial, the phase advance of its spectral peak between the halves
///    gives its frequency with very high resolution (exact for a stationary sinusoid).
/// 3. **Stiff-string fit** for weak fundamentals: wound low strings heard through a microphone
///    often have a fundamental 20–40 dB below partials 2…6, and those partials are sharp
///    (inharmonicity: fₕ = h·f₀·√(1+B·h²)). Instead of dividing one partial by h (which reads
///    1–2 ¢ sharp), all partials are measured and (fₕ/h)² = a + b·h² is fitted, weighted by each
///    partial's SNR; the fundamental is f₁ = √(a+b). A strong fundamental is used directly.
final class PitchDetector {
    let size: Int
    let sampleRate: Double
    var minFrequency: Double = 25
    var maxFrequency: Double = 2000
    var gate: Float = 0.001
    var clarityThreshold: Float = 0.6

    /// Partials used for the stiff-string fit.
    private let maxPartials = 8
    private let maxPartialHz = 1600.0
    /// Fundamental SNR above which it is used on its own (≈ 50 dB).
    private let strongFundamentalSNR = 300.0
    /// Minimum SNR for a partial to enter the fit (20 dB).
    private let minPartialSNR = 10.0

    private let half: Int
    private let log2n: vDSP_Length
    private let log2size: vDSP_Length
    private let fft: FFTSetup
    private let x: UnsafeMutablePointer<Float>
    private let pad: UnsafeMutablePointer<Float>
    private let re: UnsafeMutablePointer<Float>
    private let im: UnsafeMutablePointer<Float>
    private let mags: UnsafeMutablePointer<Float>
    private let nsdf: UnsafeMutablePointer<Float>
    private var peaks: [(tau: Int, value: Float)] = []

    // Phase-vocoder state: two half-window segments, FFT length = size (2× zero padding).
    private let hann: UnsafeMutablePointer<Float>   // half
    private let seg: UnsafeMutablePointer<Float>    // size (half samples + half zeros)
    private let aRe: UnsafeMutablePointer<Float>    // half bins each
    private let aIm: UnsafeMutablePointer<Float>
    private let bRe: UnsafeMutablePointer<Float>
    private let bIm: UnsafeMutablePointer<Float>
    private let pmag: UnsafeMutablePointer<Float>
    private var noiseScratch: [Float] = []
    private var parts: [(h: Double, f: Double, snr: Double)] = []
    private var phaseSign: Double = 1

    init(size: Int, sampleRate: Double) {
        precondition(size >= 1024 && size.nonzeroBitCount == 1, "window must be a power of two")
        self.size = size
        self.sampleRate = sampleRate
        half = size / 2
        log2n = vDSP_Length((2 * size).trailingZeroBitCount)
        log2size = vDSP_Length(size.trailingZeroBitCount)
        fft = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2))!
        x = .allocate(capacity: size)
        pad = .allocate(capacity: 2 * size)
        re = .allocate(capacity: size)
        im = .allocate(capacity: size)
        mags = .allocate(capacity: size)
        nsdf = .allocate(capacity: size / 2 + 2)
        hann = .allocate(capacity: size / 2)
        seg = .allocate(capacity: size)
        aRe = .allocate(capacity: size / 2)
        aIm = .allocate(capacity: size / 2)
        bRe = .allocate(capacity: size / 2)
        bIm = .allocate(capacity: size / 2)
        pmag = .allocate(capacity: size / 2)
        peaks.reserveCapacity(256)
        noiseScratch.reserveCapacity(size / 2)
        parts.reserveCapacity(maxPartials)
        for k in 0..<half {
            hann[k] = Float(0.5 - 0.5 * cos(2 * Double.pi * Double(k) / Double(half - 1)))
        }
        selfTestPhaseConvention()
    }

    deinit {
        vDSP_destroy_fftsetup(fft)
        x.deallocate(); pad.deallocate(); re.deallocate(); im.deallocate()
        mags.deallocate(); nsdf.deallocate()
        hann.deallocate(); seg.deallocate()
        aRe.deallocate(); aIm.deallocate(); bRe.deallocate(); bIm.deallocate(); pmag.deallocate()
    }

    /// Verifies the sign convention of the FFT phase once, with a synthetic tone between bins.
    private func selfTestPhaseConvention() {
        let f = sampleRate * 37.3 / Double(size)
        for i in 0..<size { x[i] = Float(sin(2 * Double.pi * f * Double(i) / sampleRate)) }
        computeSpectra()
        phaseSign = 1
        let plus = measurePartial(near: f)?.freq ?? 0
        if abs(plus / f - 1) > 1e-4 {
            phaseSign = -1
            let minus = measurePartial(near: f)?.freq ?? 0
            if abs(minus / f - 1) > 1e-4 { phaseSign = 1 }
        }
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
        let fine = refine(coarse)
        return PitchResult(rms: rms, frequency: fine, clarity: pick.value)
    }

    // MARK: Phase-vocoder refinement

    /// Spectra of x[0..<half] and x[half..<size], Hann-windowed, zero-padded to `size`.
    private func computeSpectra() {
        let nComplex = vDSP_Length(half)
        memset(seg + half, 0, half * 4)

        vDSP_vmul(x, 1, hann, 1, seg, 1, vDSP_Length(half))
        var sa = DSPSplitComplex(realp: aRe, imagp: aIm)
        seg.withMemoryRebound(to: DSPComplex.self, capacity: half) { vDSP_ctoz($0, 2, &sa, 1, nComplex) }
        vDSP_fft_zrip(fft, &sa, 1, log2size, FFTDirection(FFT_FORWARD))

        vDSP_vmul(x + half, 1, hann, 1, seg, 1, vDSP_Length(half))
        var sb = DSPSplitComplex(realp: bRe, imagp: bIm)
        seg.withMemoryRebound(to: DSPComplex.self, capacity: half) { vDSP_ctoz($0, 2, &sb, 1, nComplex) }
        vDSP_fft_zrip(fft, &sb, 1, log2size, FFTDirection(FFT_FORWARD))

        // Bin 0 packs DC and Nyquist; it is never used as a partial.
        pmag[0] = 0
        for k in 1..<half {
            let a = hypotf(aRe[k], aIm[k]), b = hypotf(bRe[k], bIm[k])
            pmag[k] = 0.5 * (a + b)
        }
    }

    /// Frequency and magnitude of the spectral peak nearest `fpred` (search ±2 bins = ±1 natural bin).
    private func measurePartial(near fpred: Double) -> (freq: Double, mag: Double)? {
        let nfft = Double(size)
        let k0 = Int((fpred * nfft / sampleRate).rounded())
        guard k0 >= 3, k0 <= half - 4 else { return nil }
        var k = k0 - 2
        for j in (k0 - 1)...(k0 + 2) where pmag[j] > pmag[k] { k = j }
        if k == k0 - 2 || k == k0 + 2 {
            guard pmag[k] >= pmag[k - 1] && pmag[k] >= pmag[k + 1] else { return nil }
        }
        let ar = Double(aRe[k]), ai = Double(aIm[k]), br = Double(bRe[k]), bi = Double(bIm[k])
        let dphi = phaseSign * atan2(bi * ar - br * ai, br * ar + bi * ai)   // arg(B · conj A)
        let hop = Double(half)
        let wk = 2 * Double.pi * Double(k) / nfft
        var d = dphi - wk * hop
        d -= 2 * Double.pi * (d / (2 * Double.pi)).rounded()
        return ((wk + d / hop) * sampleRate / (2 * Double.pi), Double(pmag[k]))
    }

    private func refine(_ coarse: Double) -> Double {
        // Needs a few periods per half window for an unbiased phase measurement.
        guard coarse * Double(half) / sampleRate >= 4 else { return coarse }
        computeSpectra()
        guard let fund = measurePartial(near: coarse) else { return coarse }
        let f1 = fund.freq

        // Noise floor: median magnitude of bins between partials (0.5·f1 … 1600 Hz),
        // excluding ±6 bins (±3 natural bins) around every harmonic.
        let nfft = Double(size)
        let binsPerHarmonic = f1 * nfft / sampleRate
        let kmin = max(1, Int(0.5 * binsPerHarmonic))
        let kmax = min(Int(min(maxPartialHz, 0.45 * sampleRate) * nfft / sampleRate), half - 1)
        noiseScratch.removeAll(keepingCapacity: true)
        if kmax > kmin {
            for k in kmin...kmax {
                let r = Double(k) / binsPerHarmonic
                if abs(r - r.rounded()) * binsPerHarmonic > 6 { noiseScratch.append(pmag[k]) }
            }
        }
        if noiseScratch.count <= 16 {
            noiseScratch.removeAll(keepingCapacity: true)
            for k in 1..<half { noiseScratch.append(pmag[k]) }
        }
        noiseScratch.sort()
        let noise = max(Double(noiseScratch[noiseScratch.count / 2]), 1e-12)
        let snr1 = fund.mag / noise
        if snr1 >= strongFundamentalSNR { return sanity(f1, coarse) }

        // Weak fundamental: measure partials 2…N, predicting each with the running stiffness B.
        parts.removeAll(keepingCapacity: true)
        parts.append((1, f1, snr1))
        var B = 0.0
        for h in 2...maxPartials {
            let hd = Double(h)
            let pred = hd * f1 * sqrt((1 + B * hd * hd) / (1 + B))
            if pred > min(maxPartialHz, 0.45 * sampleRate) { break }
            guard let r = measurePartial(near: pred), abs(r.freq / pred - 1) <= 0.012 else { continue }
            parts.append((hd, r.freq, r.mag / noise))
            B = stiffnessFit().B
        }
        let fit = stiffnessFit()
        guard fit.valid else { return snr1 >= minPartialSNR ? sanity(f1, coarse) : coarse }
        return sanity(sqrt(fit.a + fit.b), coarse)
    }

    /// Weighted least squares (fₕ/h)² = a + b·h² over partials with SNR ≥ 20 dB.
    /// Weights (h·SNR)² follow the variance of each partial's estimate of f₁.
    private func stiffnessFit() -> (valid: Bool, a: Double, b: Double, B: Double) {
        var s0 = 0.0, s1 = 0.0, s2 = 0.0, t0 = 0.0, t1 = 0.0
        var count = 0
        for p in parts where p.snr >= minPartialSNR {
            let y = (p.f / p.h) * (p.f / p.h)
            let w = (p.h * p.snr) * (p.h * p.snr)
            let h2 = p.h * p.h
            s0 += w; s1 += w * h2; s2 += w * h2 * h2
            t0 += w * y; t1 += w * y * h2
            count += 1
        }
        guard count >= 2, s0 > 0 else { return (false, 0, 0, 0) }
        if count >= 3 {
            let det = s0 * s2 - s1 * s1
            if det > 0 {
                let b = (s0 * t1 - s1 * t0) / det
                let a = (t0 - b * s1) / s0
                if a > 0 && b >= 0 && b / a <= 2e-3 { return (true, a, b, b / a) }
            }
        }
        return (true, t0 / s0, 0, 0)    // two partials, or an implausible stiffness: B = 0
    }

    /// The refined value must stay within 50 ¢ of the robust MPM estimate (rejects wrong-partial locks).
    private func sanity(_ value: Double, _ coarse: Double) -> Double {
        guard value.isFinite, value > 0, abs(1200 * log2(value / coarse)) <= 50 else { return coarse }
        return value
    }
}
