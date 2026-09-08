import SwiftUI

/// The live waveform in the pill (FB-02): 14 thin bars, light grey, each height driven by one raw
/// RMS level 0…1 from `DictationCoordinator.levels`. Scaling raw level → bar height is rendering,
/// not logic, so it lives here rather than in `FlowBarContent`.
struct WaveformView: View {
    static let barCount = 14
    private static let barWidth: CGFloat = 3
    private static let barGap: CGFloat = 2
    private static let minHeight: CGFloat = 4
    private static let maxHeight: CGFloat = 20

    let levels: [Float]

    var body: some View {
        HStack(alignment: .center, spacing: Self.barGap) {
            ForEach(0..<Self.barCount, id: \.self) { index in
                Capsule()
                    .fill(Color.white.opacity(0.55))
                    .frame(width: Self.barWidth, height: height(for: index))
            }
        }
        .frame(height: Self.maxHeight)
        .animation(.linear(duration: 0.05), value: levels)
    }

    private func height(for index: Int) -> CGFloat {
        let level = index < levels.count ? levels[index] : 0
        let scaled = min(1, level * 8)
        return Self.minHeight + CGFloat(scaled) * (Self.maxHeight - Self.minHeight)
    }
}
