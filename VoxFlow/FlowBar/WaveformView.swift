import SwiftUI

/// The live waveform in the pill (FB-02, canvas 3d): 14 thin, low-amplitude bars — a ripple, not a
/// barcode. Bar count comes from `levels.count` itself (no separate hardcoded constant to drift out
/// of sync with `DictationCoordinator.barCount`); each bar's height is driven by one raw RMS level
/// 0…1. At rest (level 0) every bar sits at the 2 pt floor, reading as the canvas's row of dots
/// ("·ıllıllı·") rather than a flat line.
struct WaveformView: View {
    private static let barWidth: CGFloat = 2
    private static let barGap: CGFloat = 2
    private static let minHeight: CGFloat = 2
    private static let maxHeight: CGFloat = 12

    let levels: [Float]
    var color: Color = .white

    var body: some View {
        HStack(alignment: .center, spacing: Self.barGap) {
            ForEach(levels.indices, id: \.self) { index in
                Capsule()
                    .fill(color.opacity(0.7))
                    .frame(width: Self.barWidth, height: height(for: levels[index]))
            }
        }
        .frame(height: Self.maxHeight)
        .animation(.linear(duration: 0.05), value: levels)
    }

    private func height(for level: Float) -> CGFloat {
        let scaled = min(1, level * 4)
        return Self.minHeight + CGFloat(scaled) * (Self.maxHeight - Self.minHeight)
    }
}
