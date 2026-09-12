import SwiftUI
import VoxFlowCore
import VoxFlowDictation

/// Settings › Audio (design ST-04, ST-04n): thin `ScrollView` wrapper around `AudioSettingsBody` —
/// split the same way `HistoryPage`/`HistoryPageBody` are, so `SettingsRenderTests` can render the
/// content directly (`ImageRenderer` doesn't reliably capture `ScrollView`).
struct AudioSettingsView: View {
    let audio: AudioViewModel

    var body: some View {
        ScrollView { AudioSettingsBody(audio: audio) }
            .frame(maxWidth: .infinity)
            .task { await audio.observeDeviceChanges() }
            .onDisappear { audio.microphoneTest?.stop() }
            .onChange(of: audio.dictationBusy) { _, busy in if busy { audio.microphoneTest?.stop() } }
    }
}

/// Capture settings use public voice-processing capabilities; attenuation is never labeled off.
struct AudioSettingsBody: View {
    let audio: AudioViewModel

    private static let silenceChoices: [TimeInterval] = Array(stride(from: FlowBarConfig.silenceStopRange.lowerBound,
                                                                      through: FlowBarConfig.silenceStopRange.upperBound, by: 1))

    var body: some View {
        @Bindable var audio = audio
        VStack(alignment: .leading, spacing: 18) {
            VStack(spacing: 0) {
                if !audio.hasDevice {
                    noDeviceBanner
                    Divider().padding(.leading, 16)
                }
                deviceRow
                Divider().padding(.leading, 16)
                levelRow
            }
            .background(.background.secondary, in: RoundedRectangle(cornerRadius: 10, style: .continuous))

            VStack(spacing: 0) {
                Toggle("Noise suppression", isOn: $audio.noiseSuppression)
                    .padding(.horizontal, 16).padding(.vertical, 10)
                Divider().padding(.leading, 16)
                HStack {
                    Text("Other audio reduction")
                    Spacer()
                    Picker("Other audio reduction", selection: $audio.otherAudioReduction) {
                        ForEach(MicrophoneProcessingOptions.Ducking.allCases, id: \.self) { level in
                            Text(level.title).tag(level)
                        }
                    }
                    .labelsHidden().frame(maxWidth: 160)
                    .disabled(!audio.noiseSuppression)
                }
                .padding(.horizontal, 16).padding(.vertical, 10)
                Text("Noise suppression uses Apple's voice processing, which always lowers other audio at least slightly. Turn it off for unprocessed input and no audio reduction. Changes apply to the next recording.")
                    .font(.caption).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16).padding(.bottom, 10)
                Divider().padding(.leading, 16)
                silenceRow(silenceStop: $audio.silenceStop)
            }
            .background(.background.secondary, in: RoundedRectangle(cornerRadius: 10, style: .continuous))

            if let test = audio.microphoneTest {
                HStack {
                    Button(test.isRunning ? "Stop test" : "Test microphone") {
                        if test.isRunning { test.stop() } else { test.start() }
                    }
                    .disabled(!test.isRunning && (!audio.hasDevice || audio.dictationBusy))
                    Text(test.state == .recording ? "Recording up to 5 seconds…" : test.state == .playing ? "Playing back…" : "Record, then listen. Audio stays in memory.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if let message = test.message {
                    Text(message).font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .padding(20)
        .frame(maxWidth: 640, alignment: .leading)
    }

    // MARK: ST-04n

    private var noDeviceBanner: some View {
        HStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 2) {
                Text(audio.unavailableInputName == nil ? "No microphone found" : "Selected microphone unavailable").fontWeight(.medium)
                Text(audio.unavailableInputName.map { "Reconnect \($0) or choose another input device." }
                     ?? "Connect a microphone or headset. VoxFlow picks it up automatically.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button("Open Sound Settings") { audio.openSoundSettings() }
                .buttonStyle(.bordered)
                .controlSize(.small)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(Color.orange.opacity(0.08))
    }

    // MARK: rows

    private var deviceRow: some View {
        @Bindable var audio = audio
        return VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Input device")
                Spacer()
                Picker("Input device", selection: $audio.selectedInputID) {
                    Text(audio.defaultDeviceName.map { "System Default (\($0))" } ?? "System Default").tag("")
                    ForEach(audio.availableInputs) { device in Text(device.name).tag(device.id) }
                    if let name = audio.unavailableInputName {
                        Text("\(name) — Unavailable").tag(audio.selectedInputID).disabled(true)
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .frame(maxWidth: 320)
                .disabled(!audio.canChangeInput)
            }
            Text(audio.canChangeInput ? "Used for dictation and microphone tests. Changes apply to the next recording."
                 : "Stop recording or the microphone test to change the input device.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private var levelRow: some View {
        HStack(spacing: 24) {
            Text("Input level").foregroundStyle(audio.hasDevice ? .primary : .secondary)
            WaveformView(levels: audio.levels)
                .colorMultiply(.primary)
                .frame(maxWidth: 320, alignment: .leading)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private func silenceRow(silenceStop: Binding<TimeInterval>) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text("Stop after silence")
                Text("Hands-free mode only").font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Picker("Stop after silence", selection: silenceStop) {
                ForEach(Self.silenceChoices, id: \.self) { seconds in
                    Text("\(Int(seconds)) second\(Int(seconds) == 1 ? "" : "s")").tag(seconds)
                }
            }
            .labelsHidden()
            .frame(maxWidth: 160)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }
}
