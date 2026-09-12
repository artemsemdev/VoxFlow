import SwiftUI
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
    }
}

/// "Noise suppression"/"Duck other audio"/"Test microphone" are omitted (ruling: dead controls with
/// no effect until phase 4).
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
                silenceRow(silenceStop: $audio.silenceStop)
            }
            .background(.background.secondary, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
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
                Text("No microphone found").fontWeight(.medium)
                Text("Connect a microphone or headset. VoxFlow picks it up automatically.")
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
        HStack {
            Text("Input device")
            Spacer()
            Text(audio.deviceName ?? "None available")
                .foregroundStyle(audio.hasDevice ? .primary : .secondary)
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
