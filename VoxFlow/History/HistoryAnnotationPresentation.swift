import Foundation
import SwiftUI
import VoxFlowCore
import VoxFlowStorage

struct HistoryAnnotationPresentation: Equatable {
    struct Decoration: Equatable {
        enum Kind: Equatable {
            case removedFiller
            case lowConfidence(Double)
        }

        let span: RawTextSpan
        let kind: Kind
    }

    let rawText: String
    let decorations: [Decoration]
    let badges: [String]

    init(record: DictationRecord) {
        rawText = record.rawText
        guard !record.isUnreadable,
              let annotations = record.annotations?.validated(for: record.rawText) else {
            decorations = []
            badges = []
            return
        }

        let fillers = annotations.removedFillerSpans ?? []
        let lowConfidence = (annotations.wordConfidences ?? []).filter(\.isLowConfidence)
        decorations = fillers.map { Decoration(span: $0, kind: .removedFiller) }
            + lowConfidence.map { Decoration(span: $0.span, kind: .lowConfidence($0.confidence)) }

        var labels: [String] = []
        if fillers.count == 1 {
            labels.append("1 filler removed")
        } else if fillers.count > 1 {
            labels.append("\(fillers.count) fillers removed")
        }
        if lowConfidence.count == 1, let confidence = lowConfidence.first?.confidence {
            labels.append("1 word \(Self.percent(confidence))% confident")
        } else if lowConfidence.count > 1 {
            let average = lowConfidence.reduce(0) { $0 + $1.confidence } / Double(lowConfidence.count)
            labels.append("\(lowConfidence.count) words \(Self.percent(average))% average confidence")
        }
        badges = labels
    }

    func attributedRawText(displayText: String, rawColor: Color, accentColor: Color) -> AttributedString {
        var result = AttributedString(displayText)
        result.foregroundColor = rawColor
        guard displayText == rawText else { return result }

        for decoration in decorations {
            guard let stringRange = decoration.span.range(in: rawText),
                  let lower = AttributedString.Index(stringRange.lowerBound, within: result),
                  let upper = AttributedString.Index(stringRange.upperBound, within: result) else { continue }
            switch decoration.kind {
            case .removedFiller:
                result[lower..<upper].foregroundColor = rawColor.opacity(0.45)
            case .lowConfidence:
                result[lower..<upper].underlineStyle = Text.LineStyle(pattern: .dot, color: accentColor)
            }
        }
        return result
    }

    private static func percent(_ confidence: Double) -> Int { Int((confidence * 100).rounded()) }
}
