import AppKit
import VoxFlowDictation

struct QuitActivity {
    let queueRunning: Bool
    let fileName: String?
    let progress: Double?
    let dictation: FlowBarState
    var pendingDictationWork = false
    var hasUnsavedTranscript = false

    var isBusy: Bool { queueRunning || dictation.hasUnfinishedCapture || pendingDictationWork || hasUnsavedTranscript }
    var title: String {
        if hasUnsavedTranscript { return "A transcript has not been saved" }
        return queueRunning ? "A file is still transcribing" : "Dictation is still in progress"
    }
    var message: String {
        if hasUnsavedTranscript {
            return "The transcript could not be saved. Quitting now discards it. Save it from Files, or choose Quit anyway."
        }
        if queueRunning {
            let detail = progress.map { " is \(Int((min(1, max(0, $0)) * 100).rounded()))% done" } ?? " is preparing to transcribe"
            let file = fileName ?? "The file queue"
            return "\(file)\(detail). Quitting now discards that progress."
        }
        return "Quitting now discards this dictation. Finish it first to keep your transcript."
    }
}

/// SYS-QUIT. The first termination attempt is cancelled while a decision/finish is pending;
/// the eventual programmatic retry is allowed exactly by this coordinator.
@MainActor final class QuitCoordinator {
    enum Choice: CaseIterable { case finish, quitAnyway, cancel }
    private(set) var allowsTermination = false
    private var pending = false
    private let snapshot: () async -> QuitActivity
    private let present: (QuitActivity) async -> Choice
    private let finish: () async -> Bool
    private let resume: () async -> Void
    private let quit: () -> Void

    init(snapshot: @escaping () async -> QuitActivity, present: @escaping (QuitActivity) async -> Choice,
         finish: @escaping () async -> Bool, resume: @escaping () async -> Void = {}, quit: @escaping () -> Void) {
        self.snapshot = snapshot; self.present = present; self.finish = finish; self.resume = resume; self.quit = quit
    }

    func request() async {
        guard !pending else { return }
        pending = true
        defer { pending = false }
        let activity = await snapshot()
        if activity.isBusy {
            switch await present(activity) {
            case .cancel: await resume(); return
            case .finish:
                guard await finish() else { await resume(); return }
            case .quitAnyway: break
            }
        }
        allowsTermination = true
        quit()
    }

    static func makeAlert(_ activity: QuitActivity) -> NSAlert {
        let alert = NSAlert()
        alert.messageText = activity.title
        alert.informativeText = activity.message
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Finish, then quit")
        alert.addButton(withTitle: "Quit anyway")
        alert.addButton(withTitle: "Cancel").keyEquivalent = "\u{1b}"
        return alert
    }

    static func present(_ activity: QuitActivity) async -> Choice {
        let alert = makeAlert(activity)
        NSApp.activate(ignoringOtherApps: true)
        let response: NSApplication.ModalResponse
        if let window = NSApp.keyWindow, window.attachedSheet == nil {
            response = await alert.beginSheetModal(for: window)
        } else {
            response = alert.runModal()
        }
        switch response {
        case .alertFirstButtonReturn: return .finish
        case .alertSecondButtonReturn: return .quitAnyway
        default: return .cancel
        }
    }
}
