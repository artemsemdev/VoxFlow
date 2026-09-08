import Foundation
import Synchronization
import Testing
import VoxFlowCore
import VoxFlowDictation
import VoxFlowModels
import VoxFlowTestSupport
@testable import VoxFlow

@Suite("PreflightBuilder")
struct PreflightBuilderTests {
    func builder(app: FrontmostApp = FrontmostApp(name: "Mail", bundleID: "com.apple.mail"), secure: Bool = false,
                 mic: PermissionState = .granted, requestResult: PermissionState = .granted,
                 readiness: ModelReadiness = .loaded, excluded: [String] = ["com.1password.1password"]) async
        -> (PreflightBuilder, FakePermissions, Counter) {
        let permissions = FakePermissions(microphone: mic, requestResult: requestResult, accessibility: true)
        let loader = FakeModelReadiness(readiness)
        let captured = Counter()
        let builder = PreflightBuilder(frontmost: FakeFrontmost(app: app, secure: secure), permissions: permissions,
                                       readiness: { await loader.readiness() },
                                       settings: DictationSettingsSnapshot(excludedBundleIDs: excluded, keepHistory: true, options: TranscriptionOptions()),
                                       captureFocus: { captured.withLock { $0 += 1 } })
        return (builder, permissions, captured)
    }

    @Test("happy path: everything granted, model loaded, focus captured once")
    func happy() async {
        let (b, _, captured) = await builder()
        let p = await b.preflight()
        #expect(p == Preflight(excludedApp: nil, secureInput: false, microphone: .granted, model: .loaded))
        #expect(captured.withLock { $0 } == 1)
    }

    @Test("excluded app and secure input gate before permissions; focus is not captured")
    func gates() async {
        let (a, _, capA) = await builder(app: FrontmostApp(name: "1Password", bundleID: "com.1password.1password"))
        #expect(await a.preflight().excludedApp == "1Password")
        #expect(capA.withLock { $0 } == 0)
        let (s, _, _) = await builder(secure: true)
        #expect(await s.preflight().secureInput)
    }

    @Test("not-determined microphone permission is requested once; denied stays denied")
    func microphone() async {
        let (b, perms, cap) = await builder(mic: .notDetermined, requestResult: .granted)
        #expect(await b.preflight().microphone == .granted)
        #expect(perms.requests == 1)
        #expect(cap.withLock { $0 } == 1)
        let (d, _, capD) = await builder(mic: .denied)
        #expect(await d.preflight().microphone == .denied)
        #expect(capD.withLock { $0 } == 0)
    }

    @Test("model readiness is passed through")
    func model() async {
        let (b, _, cap) = await builder(readiness: .notInstalled(sizeBytes: 1_624_555_275))
        #expect(await b.preflight().model == .notInstalled(sizeBytes: 1_624_555_275))
        #expect(cap.withLock { $0 } == 0)
    }
}

struct FakeFrontmost: FrontmostAppProviding {
    let app: FrontmostApp; let secure: Bool
    func frontmostApp() -> FrontmostApp { app }
    func secureInputEnabled() -> Bool { secure }
}

actor FakeModelReadiness {
    let value: ModelReadiness
    init(_ value: ModelReadiness) { self.value = value }
    func readiness() -> ModelReadiness { value }
}

/// `Mutex<Int>` can't sit inside a tuple (`Mutex` is `~Copyable`, and Swift doesn't yet support
/// noncopyable tuple elements) — this forwards to one so the helper below can still return a plain
/// tuple, keeping `withLock` call sites identical to using a `Mutex` directly.
final class Counter: Sendable {
    private let box = Mutex(0)
    func withLock<T>(_ body: (inout Int) throws -> sending T) rethrows -> sending T { try box.withLock(body) }
}
