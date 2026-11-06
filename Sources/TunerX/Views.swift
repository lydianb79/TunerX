import CoreAudio
import SwiftUI

struct ContentView: View {
    @EnvironmentObject var model: TunerModel

    var body: some View {
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                ReadoutView(live: model.live)
                MetalTunerView(state: model.display)
                    .frame(minHeight: 420)
            }
            .background(Color(red: 0.028, green: 0.031, blue: 0.039))
            Divider()
            SettingsView(live: model.live)
                .frame(width: 330)
        }
    }
}

// MARK: Header readout

struct ReadoutView: View {
    @ObservedObject var live: LiveReadout

    private func color(_ c: Double) -> Color {
        let a = abs(c)
        if a < 1 { return Color(red: 0.25, green: 1, blue: 0.55) }
        if a < 5 { return Color(red: 1, green: 0.84, blue: 0.25) }
        return Color(red: 1, green: 0.36, blue: 0.28)
    }

    var body: some View {
        let r = live.value
        let dim = r.hasSignal ? 1.0 : 0.3
        HStack(alignment: .center, spacing: 32) {
            HStack(alignment: .lastTextBaseline, spacing: 2) {
                Text(r.noteName)
                    .font(.system(size: 86, weight: .bold, design: .rounded))
                Text(r.octave)
                    .font(.system(size: 30, weight: .semibold, design: .rounded))
                    .foregroundStyle(.secondary)
            }
            .frame(minWidth: 170, alignment: .leading)
            .foregroundColor(r.hasSignal ? color(r.cents) : .white)

            VStack(alignment: .leading, spacing: 4) {
                Text(String(format: "%+.2f ¢", r.cents))
                    .font(.system(size: 44, weight: .semibold, design: .monospaced))
                    .foregroundColor(color(r.cents))
                Text(statusText(r))
                    .font(.system(size: 14, weight: .semibold, design: .rounded))
                    .foregroundStyle(.secondary)
                    .textCase(.uppercase)
            }

            Spacer()

            Grid(alignment: .trailing, horizontalSpacing: 14, verticalSpacing: 4) {
                row("Measured", String(format: "%.4f Hz", r.frequency))
                row("Target", String(format: "%.4f Hz", r.target))
                row("Deviation", String(format: "%+.4f Hz", r.frequency - r.target))
                row("Clarity", String(format: "%.3f", r.clarity))
            }
        }
        .opacity(dim)
        .animation(.easeOut(duration: 0.25), value: r.hasSignal)
        .padding(.horizontal, 28)
        .padding(.vertical, 12)
        .foregroundColor(.white)
    }

    private func statusText(_ r: Readout) -> String {
        guard r.hasSignal else { return "Play a note" }
        if abs(r.cents) < 0.5 { return "In tune" }
        return r.cents < 0 ? "♭ Flat – tune up" : "♯ Sharp – tune down"
    }

    @ViewBuilder private func row(_ label: String, _ value: String) -> some View {
        GridRow {
            Text(label).foregroundStyle(.secondary)
            Text(value).font(.system(size: 15, weight: .medium, design: .monospaced))
        }
        .font(.system(size: 13))
    }
}

// MARK: Settings

struct SettingsView: View {
    @EnvironmentObject var model: TunerModel
    @ObservedObject var live: LiveReadout

    private let refNotes: [(String, Int)] = [("Follow detected note", -1), ("E2 – low E", 40), ("A2", 45), ("D3", 50),
                                             ("G3", 55), ("B3", 59), ("E4 – high E", 64), ("A4", 69), ("B1 – 7-string", 35)]

    var body: some View {
        Form {
            Section("Input") {
                Picker("Device", selection: $model.inputDeviceID) {
                    ForEach(model.inputDevices) { d in Text(d.name).tag(d.id) }
                }
                Picker("Channel", selection: $model.inputChannel) {
                    Text("Mix all").tag(-1)
                    ForEach(0..<max(model.inputChannelCount, 0), id: \.self) { i in Text("Input \(i + 1)").tag(i) }
                }
                LevelMeter(db: live.value.levelDB)
            }

            Section("Output") {
                Picker("Device", selection: $model.outputDeviceID) {
                    Text("None").tag(AudioDeviceID(0))
                    ForEach(model.outputDevices) { d in Text(d.name).tag(d.id) }
                }
                Toggle("Reference tone", isOn: $model.refToneEnabled)
                Picker("Tone pitch", selection: $model.refToneMidi) {
                    ForEach(refNotes.indices, id: \.self) { i in Text(refNotes[i].0).tag(refNotes[i].1) }
                }
                .disabled(!model.refToneEnabled)
                LabeledContent("Tone level") { Slider(value: $model.refToneVolume, in: 0...1) }
                Toggle("Input monitoring", isOn: $model.monitorEnabled)
                LabeledContent("Monitor level") { Slider(value: $model.monitorVolume, in: 0...1) }
                    .disabled(!model.monitorEnabled)
            }
            .disabled(model.outputDeviceID == 0)

            Section("Driver") {
                Picker("Buffer size", selection: $model.bufferSize) {
                    ForEach(model.availableBufferSizes, id: \.self) { b in
                        Text(String(format: "%u samples  (%.2f ms)", b, Double(b) / model.sampleRate * 1000)).tag(b)
                    }
                }
                Picker("Sample rate", selection: $model.sampleRate) {
                    ForEach(model.availableSampleRates, id: \.self) { sr in
                        Text(String(format: "%.1f kHz", sr / 1000)).tag(sr)
                    }
                }
                if !model.activeInfo.isEmpty {
                    Text(model.activeInfo).font(.caption).foregroundStyle(.secondary)
                }
            }

            Section("Analysis") {
                Picker("Window", selection: $model.analysisWindow) {
                    ForEach(AnalysisWindow.allCases) { w in Text(w.label).tag(w) }
                }
                LabeledContent("Reference A4") {
                    HStack(spacing: 6) {
                        TextField("", value: $model.a4, format: .number.precision(.fractionLength(1)))
                            .frame(width: 64)
                            .multilineTextAlignment(.trailing)
                        Text("Hz")
                        Stepper("", value: $model.a4, in: 400...480, step: 0.1).labelsHidden()
                    }
                }
                LabeledContent("Smoothing") { Slider(value: $model.smoothing, in: 0...1) }
                LabeledContent(String(format: "Noise gate  %.0f dB", model.gateDB)) {
                    Slider(value: $model.gateDB, in: -90...(-20))
                }
            }

            Section {
                Text(model.status).font(.caption).foregroundStyle(model.status == "Running" ? Color.green : Color.orange)
                Button("Rescan audio devices") { model.refreshDevices(initial: false) }
            }
        }
        .formStyle(.grouped)
    }
}

struct LevelMeter: View {
    let db: Float

    var body: some View {
        let norm = CGFloat(max(0, min(1, (db + 72) / 72)))
        HStack {
            Text("Level").foregroundStyle(.secondary)
            GeometryReader { g in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 3).fill(Color.white.opacity(0.08))
                    RoundedRectangle(cornerRadius: 3)
                        .fill(LinearGradient(colors: [.green, .yellow, .red], startPoint: .leading, endPoint: .trailing))
                        .frame(width: g.size.width)
                        .mask(alignment: .leading) {
                            Rectangle().frame(width: g.size.width * norm)
                        }
                }
            }
            .frame(height: 8)
            Text(db <= -119 ? "–∞" : String(format: "%.0f dB", db))
                .font(.system(size: 11, design: .monospaced))
                .frame(width: 52, alignment: .trailing)
        }
    }
}
