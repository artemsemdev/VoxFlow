import AppKit
import SwiftUI
import Testing
import VoxFlowCore
import VoxFlowDictation
@testable import VoxFlow

/// Design-fidelity renders (Task 4 Step 4) — gated behind `VOXFLOW_RENDER` so normal test runs
/// never touch disk. Run with `VOXFLOW_RENDER=1 xcodebuild … -only-testing:VoxFlowTests/FlowBarRenderTests`,
/// then compare the PNGs in `.superpowers/design/renders/` against `canvas.pdf` pages 8–9 and 11.
@Suite(.enabled(if: ProcessInfo.processInfo.environment["VOXFLOW_RENDER"] != nil))
@MainActor
struct FlowBarRenderTests {
    /// 14 varying, low-amplitude levels — the D1 ruling's display gain (`min(1, level * 4)`)
    /// saturates at `level == 0.25`, so realistic-looking speech (a ripple, not a wall of maxed-out
    /// bars) needs values mostly well under that, with a couple of small peaks for visible variation.
    private static let levels: [Float] = [0.02, 0.08, 0.18, 0.05, 0.12, 0.22, 0.04, 0.15, 0.03, 0.1, 0.19, 0.02, 0.13, 0.06]

    private struct RenderCase {
        let name: String
        let state: FlowBarState
        let elapsed: TimeInterval
        let mode: HotkeyMode
        /// Wide enough for every normal state (40 pt pill, generous margin); a couple of cases
        /// widen this to see the full 560 pt pill cap (N7) without the canvas itself clipping first.
        var canvasWidth: CGFloat = 420
    }

    private static let cases: [RenderCase] = [
        RenderCase(name: "idle-ptt", state: .idle, elapsed: 0, mode: .pushToTalk),
        RenderCase(name: "idle-handsfree", state: .idle, elapsed: 0, mode: .handsFree),
        RenderCase(name: "listening-en", state: .listening(Listening(mode: .pushToTalk, startedAt: 0,
                    language: LanguageDetection(code: "en", confidence: 0.4))), elapsed: 4, mode: .pushToTalk),
        RenderCase(name: "listening-handsfree", state: .listening(Listening(mode: .handsFree, startedAt: 0, language: nil)),
                    elapsed: 84, mode: .pushToTalk),
        RenderCase(name: "processing", state: .processing(Processing(startedAt: 0, takingLonger: false, limitReached: false, partialText: "")),
                    elapsed: 1, mode: .pushToTalk),
        RenderCase(name: "processing-taking-longer", state: .processing(Processing(startedAt: 0, takingLonger: true, limitReached: false, partialText: "")),
                    elapsed: 9, mode: .pushToTalk),
        RenderCase(name: "inserted-mail", state: .inserted(appName: "Mail", words: 42, limitReached: false), elapsed: 0, mode: .pushToTalk),
        RenderCase(name: "copied", state: .copied, elapsed: 0, mode: .pushToTalk),
        RenderCase(name: "didnt-catch", state: .didntCatch(rawAvailable: false), elapsed: 0, mode: .pushToTalk),
        RenderCase(name: "didnt-catch-raw", state: .didntCatch(rawAvailable: true), elapsed: 0, mode: .pushToTalk),
        RenderCase(name: "discarded", state: .discarded, elapsed: 0, mode: .pushToTalk),
        RenderCase(name: "mic-denied", state: .micUnavailable(.denied), elapsed: 0, mode: .pushToTalk),
        RenderCase(name: "mic-in-use", state: .micUnavailable(.inUse(by: nil)), elapsed: 0, mode: .pushToTalk),
        RenderCase(name: "mic-no-device", state: .micUnavailable(.noDevice), elapsed: 0, mode: .pushToTalk),
        RenderCase(name: "model-missing", state: .modelNotInstalled(sizeBytes: 1_624_555_275), elapsed: 0, mode: .pushToTalk),
        RenderCase(name: "excluded", state: .excluded(app: "1Password"), elapsed: 0, mode: .pushToTalk),
        RenderCase(name: "loading", state: .loadingModel(Pending(downAt: 0, fnIsDown: true, resolvedMode: nil)), elapsed: 0, mode: .pushToTalk),
        RenderCase(name: "error", state: .error("Couldn't load the speech model"), elapsed: 0, mode: .pushToTalk),
        RenderCase(name: "armed", state: .armed(Pending(downAt: 0, fnIsDown: true, resolvedMode: nil)), elapsed: 0, mode: .pushToTalk),
        // N7: an app name with no length the model can bound — must truncate the title (and cap the
        // pill at 560 pt) rather than grow forever or (like the D2 chip bug) collapse to nothing.
        RenderCase(name: "excluded-long-app-name",
                    state: .excluded(app: "Some Very Long Enterprise Application Name Incorporated LLC"),
                    elapsed: 0, mode: .pushToTalk, canvasWidth: 620),
    ]

    @Test("renders every Flow Bar state for design-fidelity comparison")
    func render() throws {
        let directory = Self.rendersDirectory()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        for (index, testCase) in Self.cases.enumerated() {
            let content = FlowBarContent.make(state: testCase.state, elapsed: testCase.elapsed, mode: testCase.mode)
            let renderer = ImageRenderer(content: RenderCanvas(content: content, levels: Self.levels, width: testCase.canvasWidth))
            renderer.scale = 2
            guard let image = renderer.nsImage else {
                Issue.record("Failed to render \(testCase.name)")
                continue
            }
            let url = directory.appendingPathComponent("FlowBar-\(index + 1)-\(testCase.name).png")
            try Self.writePNG(image, to: url)
        }
    }

    private static func rendersDirectory() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // VoxFlowTests/
            .deletingLastPathComponent()   // repo root
            .appendingPathComponent(".superpowers/design/renders")
    }

    private static func writePNG(_ image: NSImage, to url: URL) throws {
        guard let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else {
            Issue.record("Failed to encode PNG for \(url.lastPathComponent)")
            return
        }
        try png.write(to: url)
    }
}

/// Fixed 420×80 canvas with the desktop-grey background from the design (`#d9dbe0`), pill centered.
private struct RenderCanvas: View {
    let content: FlowBarContent
    let levels: [Float]
    var width: CGFloat = 420

    var body: some View {
        ZStack {
            Color(red: 0xd9 / 255, green: 0xdb / 255, blue: 0xe0 / 255)
            FlowBarView(content: content, levels: levels)
        }
        .frame(width: width, height: 80)
    }
}
