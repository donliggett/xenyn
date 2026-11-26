import SwiftUI

struct ContentView: View {
    @ObservedObject var model: AppModel

    private let columns = [GridItem(.adaptive(minimum: 120), spacing: 8)]

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header
            Divider()
            voiceSection
            Divider()
            clipsSection
            Divider()
            monitorSection
            Divider()
            recordSection
            Spacer(minLength: 0)
            panicButton
            legend
        }
        .padding(20)
    }

    // MARK: Sections

    private var header: some View {
        HStack(alignment: .center, spacing: 8) {
            Text("XENYN")
                .font(.system(size: 22, weight: .heavy, design: .monospaced))
                .tracking(6)
            Spacer()
            Circle()
                .fill(model.live ? Color.green : Color.red)
                .frame(width: 8, height: 8)
            Text(model.status)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .multilineTextAlignment(.trailing)
            if !model.live {
                Button("Retry") { model.start() }
            }
        }
    }

    private var voiceSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            title("Voice")
            HStack {
                Toggle("Mic", isOn: $model.micEnabled)
                Toggle("Effect", isOn: $model.voiceEnabled)
                Spacer()
                Picker("Effect", selection: $model.voiceKind) {
                    Text(VoiceKind.builtIn.rawValue).tag(VoiceKind.builtIn)
                    if model.graillonAvailable {
                        Text(VoiceKind.graillon.rawValue).tag(VoiceKind.graillon)
                    }
                }
                .labelsHidden()
                .frame(width: 160)
            }
            if model.voiceKind == .builtIn {
                slider("Pitch", value: $model.pitchSemitones, in: -12...12, step: 1) {
                    String(format: "%+.0f st", $0)
                }
            } else {
                Button("Open Graillon…") { model.openGraillonEditor() }
            }
            HStack {
                Picker("Input", selection: $model.micID) {
                    ForEach(model.micOptions) { Text($0.name).tag($0.id) }
                }
                Button {
                    model.refreshMics()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .help("Rescan microphones")
            }
            slider("Mic level", value: $model.micGain, in: 0...2) { String(format: "%.0f%%", $0 * 100) }
        }
    }

    private var clipsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                title("Clips")
                Spacer()
                Button("Folder") { model.revealClipsFolder() }
                Button("Reload") { model.reloadClips() }
            }
            if model.clips.isEmpty {
                Text("Drop audio files into ~/Music/Xenyn/Clips, then press Reload.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                ScrollView {
                    LazyVGrid(columns: columns, alignment: .leading, spacing: 8) {
                        ForEach(Array(model.clips.enumerated()), id: \.element.id) { index, clip in
                            clipButton(clip, index: index)
                        }
                    }
                }
                .frame(maxHeight: 180)
            }
            slider("Clip level", value: $model.clipGain, in: 0...1.5) { String(format: "%.0f%%", $0 * 100) }
            HStack {
                Toggle("Ramble", isOn: Binding(get: { model.rambleOn }, set: { model.setRamble($0) }))
                    .toggleStyle(.switch)
                slider("Gap", value: $model.rambleGap, in: 0.5...10) { String(format: "%.1f s", $0) }
            }
        }
    }

    private var monitorSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            title("Monitor")
            if model.monitorAvailable {
                HStack {
                    Toggle("Hear clips", isOn: $model.monitorOn)
                    slider("Level", value: $model.monitorGain, in: 0...1.5) { String(format: "%.0f%%", $0 * 100) }
                }
            } else {
                Text("No monitor output (the system output is BlackHole or unavailable).")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var recordSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                title("Record")
                Spacer()
                Button {
                    model.toggleRecording()
                } label: {
                    Label(model.recording ? "Stop" : "Record",
                          systemImage: model.recording ? "stop.fill" : "record.circle")
                }
                .tint(model.recording ? Color.red : nil)
                Button("Folder") { model.revealRecordingsFolder() }
            }
            Picker("Caller audio", selection: $model.callerSourceID) {
                ForEach(model.callerOptions) { Text($0.name).tag($0.id) }
            }
            .disabled(model.recording)
        }
    }

    private var panicButton: some View {
        Button {
            model.panic()
        } label: {
            Text("PANIC · stop clips, clean voice")
                .font(.system(.body, design: .monospaced).weight(.bold))
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderedProminent)
        .tint(.red)
        .controlSize(.large)
    }

    private var legend: some View {
        Text("⌃⌥1–9 clip · ⌃⌥0 stop · ⌃⌥R ramble · ⌃⌥M mic · ⌃⌥V effect · ⌃⌥E record · ⌃⌥Space panic")
            .font(.caption2.monospaced())
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity)
    }

    // MARK: Pieces

    private func title(_ text: String) -> some View {
        Text(text.uppercased())
            .font(.caption.weight(.semibold).monospaced())
            .foregroundStyle(.secondary)
            .tracking(2)
    }

    private func clipButton(_ clip: Clip, index: Int) -> some View {
        let playing = model.playingID == clip.id
        return Button {
            playing ? model.stopClips() : model.play(clip)
        } label: {
            HStack(spacing: 6) {
                Text(index < 9 ? "\(index + 1)" : "·")
                    .font(.caption.monospaced().weight(.bold))
                    .foregroundStyle(.secondary)
                Text(clip.name)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 0)
                if playing { Image(systemName: "speaker.wave.2.fill") }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(.bordered)
        .tint(playing ? Color.accentColor : nil)
    }

    private func slider(
        _ label: String,
        value: Binding<Double>,
        in range: ClosedRange<Double>,
        step: Double? = nil,
        format: @escaping (Double) -> String
    ) -> some View {
        HStack {
            Text(label).frame(width: 70, alignment: .leading)
            if let step {
                Slider(value: value, in: range, step: step)
            } else {
                Slider(value: value, in: range)
            }
            Text(format(value.wrappedValue))
                .font(.caption.monospacedDigit())
                .frame(width: 56, alignment: .trailing)
        }
    }
}
