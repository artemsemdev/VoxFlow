import AppKit
import CryptoKit
import Foundation
import Synchronization
import SwiftUI
import Testing
import VoxFlowCore
import VoxFlowStorage
import VoxFlowTestSupport
@testable import VoxFlow

private struct InsecureKeyProvider: HistoryKeyProviding {
    func historyKey() throws -> HistoryKey { HistoryKey(key: .init(size: .bits256), isNewlyCreated: true) }
}

/// A `ContactsImporting` whose `fetchNames()` never returns until `unblock()` is called — lets a
/// render case snapshot `.importing` mid-flight instead of racing past it, the same way a real
/// import stays in that state until the fetch completes.
private final class BlockingContacts: ContactsImporting, Sendable {
    private let continuation = Mutex<CheckedContinuation<[String], Error>?>(nil)
    private let names: [String]
    init(names: [String]) { self.names = names }
    func authorization() -> PermissionState { .granted }
    func request() async -> PermissionState { .granted }
    func fetchNames() async throws -> [String] {
        try await withCheckedThrowingContinuation { k in self.continuation.withLock { $0 = k } }
    }
    func unblock() { continuation.withLock { $0?.resume(returning: names); $0 = nil } }
    func observeChanges(_ handler: @escaping @Sendable () -> Void) -> ContactsChangeToken { ContactsChangeToken {} }
}

/// Design-fidelity renders (Task 4 Step 3) — gated behind `VOXFLOW_RENDER`, same convention as
/// `HistoryRenderTests`. Run with `TEST_RUNNER_VOXFLOW_RENDER=1 xcodebuild … -only-testing:VoxFlowTests/DictionaryRenderTests`
/// (the `TEST_RUNNER_` prefix is required — a bare `VOXFLOW_RENDER=1` in the shell doesn't reach the
/// test host process, confirmed empirically; see `SettingsRenderTests`/`OnboardingRenderTests` for the
/// same note), then compare the PNGs in `.superpowers/design/renders/` against `canvas.pdf` page 4
/// (MW-03v), 5 (MW-03c), 8 (MW-03a), 9 (MW-03e), and the canvas HTML's `words` sample rows for the
/// MW-03 list.
///
/// Known `ImageRenderer` limitation (confirmed empirically, not a real UI bug — see
/// `SettingsRenderTests`'s doc comment for the first writeup): `Toggle`/`Picker`/`Menu` rasterize as a
/// plain yellow "unavailable cursor" glyph instead of their real appearance. So in these PNGs: the
/// switch on the Contacts row (5/6/7) and the "Also fix it when I type it wrong" checkbox (3/4) show
/// that glyph — everything else is representative. Verify Toggle/checkbox appearance by running the
/// live app instead.
@Suite(.enabled(if: ProcessInfo.processInfo.environment["VOXFLOW_RENDER"] != nil))
@MainActor
struct DictionaryRenderTests {
    private struct Bundle {
        let vm: DictionaryViewModel
        let content: ContentService
        let styling: StylingSettings
        let dir: TemporaryDirectory
    }

    /// The canvas HTML's six sample rows (`design/VoxFlow.dc.html`'s `words` array).
    private static let sampleWords: [(word: String, sounds: String?, type: DictionaryEntryType, uses: Int)] = [
        ("VoxFlow", "vox flow", .product, 212),
        ("Anh Nguyen", "on win", .name, 96),
        ("Priya Raghunathan", "pree-ya rag-oo-NA-than", .name, 41),
        ("Kubernetes", nil, .term, 38),
        ("PostgreSQL", "postgres", .term, 27),
        ("Tāmaki Makaurau", "tah-ma-kee ma-ko-row", .place, 6),
    ]

    private func makeBundle(contacts: any ContactsImporting = FakeContacts()) -> Bundle {
        let dir = TemporaryDirectory()
        let settings = DictationSettings(store: InMemoryKeyValueStore())
        let styling = StylingSettings(store: InMemoryKeyValueStore())
        let service = HistoryService(url: dir.file("voxflow.sqlite"), settings: settings, keyProvider: { InsecureKeyProvider() },
                                     clock: SystemMonotonicClock())
        let content = ContentService(history: service)
        let vm = DictionaryViewModel(content: content, contactsImporter: contacts, stylingSettings: styling, openURL: { _ in })
        return Bundle(vm: vm, content: content, styling: styling, dir: dir)
    }

    private func waitFor(_ predicate: () -> Bool) async {
        for _ in 0..<2_000 where !predicate() { await Task.yield() }
    }

    @Test("renders Dictionary states for design-fidelity comparison")
    func render() async throws {
        let directory = Self.rendersDirectory()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        // 1. MW-03 list — the canvas's six sample rows with their uses counts.
        let listBundle = makeBundle()
        for sample in Self.sampleWords {
            _ = try? await listBundle.content.dictionary.insert(word: sample.word, soundsLike: sample.sounds, type: sample.type, fixTyping: false)
        }
        var words: [String] = []
        for sample in Self.sampleWords { words.append(contentsOf: Array(repeating: sample.word, count: sample.uses)) }
        await listBundle.content.noteUses(words: words, snippets: [])
        await listBundle.vm.load()
        try Self.render(DictionaryRenderPreview(viewModel: listBundle.vm), name: "1-list", directory: directory)

        // 2. MW-03e — empty dictionary.
        let emptyBundle = makeBundle()
        await emptyBundle.vm.load()
        try Self.render(DictionaryRenderPreview(viewModel: emptyBundle.vm), name: "2-empty", directory: directory)

        // 3. MW-03a — blank "Add word" sheet.
        let addBundle = makeBundle()
        await addBundle.vm.load()
        addBundle.vm.presentAdd()
        try Self.render(AddWordSheetRenderPreview(viewModel: addBundle.vm), name: "3-sheet-add", directory: directory)

        // 4. MW-03v — duplicate validation ("Kubernetes" already present), Add disabled, "Edit existing".
        let validationBundle = makeBundle()
        _ = try? await validationBundle.content.dictionary.insert(word: "Kubernetes", soundsLike: nil, type: .term, fixTyping: false)
        await validationBundle.vm.load()
        validationBundle.vm.presentAdd()
        validationBundle.vm.sheet?.word = "Kubernetes"
        try Self.render(AddWordSheetRenderPreview(viewModel: validationBundle.vm), name: "4-validation-duplicate", directory: directory)

        // 5. MW-03c importing — a blocked fetch snapshotted mid-flight.
        let blocking = BlockingContacts(names: ["Anh Nguyen"])
        let importingBundle = makeBundle(contacts: blocking)
        await importingBundle.vm.load()
        let importTask = Task { await importingBundle.vm.setLearnFromContacts(true) }
        await waitFor { importingBundle.vm.contacts == .importing }
        try Self.render(DictionaryContactsRow(viewModel: importingBundle.vm).frame(width: 860).padding(20).background(Color(nsColor: .windowBackgroundColor)),
                        name: "5-contacts-importing", directory: directory)
        blocking.unblock()
        await importTask.value

        // 6. MW-03c success — "N names added · updates when Contacts change".
        let doneNames = (1...312).map { "Contact \($0)" }
        let doneBundle = makeBundle(contacts: FakeContacts(authorization: .granted, names: doneNames))
        await doneBundle.vm.load()
        await doneBundle.vm.setLearnFromContacts(true)
        try Self.render(DictionaryContactsRow(viewModel: doneBundle.vm).frame(width: 860).padding(20).background(Color(nsColor: .windowBackgroundColor)),
                        name: "6-contacts-done", directory: directory)

        // 7. MW-03c denied — amber row, "Open System Settings", toggle snapped back off.
        let deniedBundle = makeBundle(contacts: FakeContacts(authorization: .denied))
        await deniedBundle.vm.load()
        await deniedBundle.vm.setLearnFromContacts(true)
        try Self.render(DictionaryContactsRow(viewModel: deniedBundle.vm).frame(width: 860).padding(20).background(Color(nsColor: .windowBackgroundColor)),
                        name: "7-contacts-denied", directory: directory)

        withExtendedLifetime([listBundle.dir, emptyBundle.dir, addBundle.dir, validationBundle.dir, importingBundle.dir, doneBundle.dir, deniedBundle.dir]) {}
    }

    @MainActor
    private static func render(_ view: some View, name: String, directory: URL) throws {
        let renderer = ImageRenderer(content: view.frame(width: 900, height: 640))
        renderer.scale = 2
        guard let image = renderer.nsImage else {
            Issue.record("Failed to render \(name)")
            return
        }
        try writePNG(image, to: directory.appendingPathComponent("Dictionary-\(name).png"))
    }

    private static func rendersDirectory() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
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

/// Renders `DictionaryPageBody`'s content sharing every content-bearing subview with production
/// (`DictionaryList`, `DictionaryEmptyView`, `DictionaryContactsRow`) — same reasoning as
/// `HistoryRenderPreview`. No live `ScrollView` (blank under `ImageRenderer`).
private struct DictionaryRenderPreview: View {
    let viewModel: DictionaryViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .lastTextBaseline, spacing: 16) {
                Text("Names and terms VoxFlow should always get right. Add how they sound if the spelling isn't obvious.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: 520, alignment: .leading)
                Spacer(minLength: 0)
                Button("+ Add word") {}
                    .buttonStyle(.borderedProminent)
            }
            if viewModel.isEmpty {
                DictionaryEmptyView(viewModel: viewModel).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                DictionaryList(viewModel: viewModel)
            }
            DictionaryContactsRow(viewModel: viewModel)
        }
        .padding(20)
        .frame(width: 900, height: 640)
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

/// The "Add word" sheet on its own (design 2c/MW-03a, MW-03v) — a live `TextField` renders as a
/// solid colour-filled glyph under `ImageRenderer` with no real window behind it (same empirical
/// finding `HistoryRenderPreview`'s doc comment describes), so the word/sounds-like fields are
/// substituted with `Text` here; `Picker`/`Toggle`/`Button` render fine and are the same controls
/// `AddWordSheet` uses.
private struct AddWordSheetRenderPreview: View {
    let viewModel: DictionaryViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Add word").font(.headline)
            wordRow
            HStack(alignment: .top, spacing: 12) {
                Text("Sounds like").foregroundStyle(.secondary).frame(width: 84, alignment: .trailing)
                Text((viewModel.sheet?.soundsLike.isEmpty == false) ? viewModel.sheet!.soundsLike : "optional — e.g. \"pree-ya\"")
                    .foregroundStyle((viewModel.sheet?.soundsLike.isEmpty == false) ? .primary : .secondary)
            }
            HStack(alignment: .top, spacing: 12) {
                Text("Type").foregroundStyle(.secondary).frame(width: 84, alignment: .trailing)
                Text(viewModel.sheet?.type.displayName ?? "Name")
            }
            Toggle("Also fix it when I type it wrong", isOn: .constant(viewModel.sheet?.fixTyping ?? false))
                .toggleStyle(.checkbox)
                .padding(.leading, 96)
            (Text("Say it once to check: ").foregroundStyle(.secondary) + Text("Hold fn and say the word").foregroundStyle(.tint))
                .font(.caption)
                .padding(.leading, 96)
            HStack {
                Spacer()
                Button("Cancel") {}
                Button(viewModel.sheet?.editingID == nil ? "Add" : "Save") {}
                    .buttonStyle(.borderedProminent)
                    .disabled(!viewModel.canAdd)
            }
        }
        .padding(20)
        .frame(width: 380)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var wordRow: some View {
        HStack(alignment: .top, spacing: 12) {
            Text("Word").foregroundStyle(.secondary).frame(width: 84, alignment: .trailing)
            VStack(alignment: .leading, spacing: 6) {
                Text(viewModel.sheet?.word ?? "")
                    .padding(6)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(isDuplicate ? Color.red : Color.secondary.opacity(0.3), lineWidth: isDuplicate ? 2 : 1))
                if case .duplicate(let existing) = viewModel.validation {
                    HStack {
                        Text("\u{201c}\(existing.word)\u{201d} is already in your dictionary.").foregroundStyle(.red)
                        Spacer()
                        Text("Edit existing").foregroundStyle(.tint)
                    }
                    .font(.caption)
                }
            }
        }
    }

    private var isDuplicate: Bool {
        if case .duplicate = viewModel.validation { return true }
        return false
    }
}
