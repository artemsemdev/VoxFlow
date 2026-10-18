import Foundation
import Testing
@testable import VoxFlowDictation

@Suite("Microphone retry intent")
struct MicrophoneRetryIntentTests {
    @Test("fn retry preserves the remaining hold decision and a completed hold")
    func holdTiming() throws {
        var intent = MicrophoneRetryIntent()
        intent.begin(mode: nil, at: 0)
        let first = intent.claim(at: 0.05)
        let ticket = try #require(first)
        let activation = intent.consume(ticket, at: 0.1)
        #expect(activation?.mode == nil)
        #expect(activation?.fnIsDown == true)
        #expect(abs((activation?.holdDelay ?? 0) - 0.15) < 0.0001)
        intent.rearm()
        let later = intent.claim(at: 1)
        let held = intent.consume(try #require(later), at: 1)
        #expect(held?.mode == .pushToTalk)
        #expect(held?.holdDelay == nil)
    }

    @Test("a single tap keeps only its remaining double-tap window")
    func tapExpires() throws {
        var intent = MicrophoneRetryIntent()
        intent.begin(mode: nil, at: 0)
        intent.update(.fnUp, at: 0.1)
        #expect(abs((intent.expiresAt ?? 0) - 0.45) < 0.0001)
        let claimed = intent.claim(at: 0.2)
        let ticket = try #require(claimed)
        let tapped = intent.consume(ticket, at: 0.2)
        #expect(tapped?.fnIsDown == false)
        #expect(tapped?.mode == nil)
        #expect(abs((tapped?.doubleTapDelay ?? 0) - 0.25) < 0.0001)
        intent.rearm()
        let expiring = intent.claim(at: 0.3)
        let expired = intent.consume(try #require(expiring), at: 0.451)
        #expect(expired == nil)
        #expect(intent.claim(at: 1) == nil)
    }

    @Test("releasing a completed hold or dedicated PTT cancels retry", arguments: [false, true])
    func releaseCancels(dedicated: Bool) {
        var intent = MicrophoneRetryIntent()
        intent.begin(mode: dedicated ? .pushToTalk : nil, at: 0)
        intent.update(dedicated ? .pushToTalkReleased : .fnUp, at: 0.3)
        #expect(intent.claim(at: 1) == nil)
    }

    @Test("a second tap enables hands-free until its normal stop gesture")
    func doubleTap() throws {
        var intent = MicrophoneRetryIntent()
        intent.begin(mode: nil, at: 0)
        intent.update(.fnUp, at: 0.1)
        intent.update(.fnDown, at: 0.2)
        intent.update(.fnUp, at: 0.25)
        let claimed = intent.claim(at: 1)
        let activation = intent.consume(try #require(claimed), at: 1)
        #expect(activation?.mode == .handsFree)
        #expect(intent.expiresAt == nil)
        intent.update(.fnDown, at: 2)
        #expect(intent.claim(at: 3) == nil)
    }

    @Test("hands-free ignores releases but obeys stop and cancellation", arguments: [false, true])
    func handsFreeStops(cancel: Bool) throws {
        var intent = MicrophoneRetryIntent()
        intent.begin(mode: .handsFree, at: 0)
        intent.update(.fnUp, at: 1)
        intent.update(.pushToTalkReleased, at: 2)
        let claimed = intent.claim(at: 3)
        let activation = intent.consume(try #require(claimed), at: 3)
        #expect(activation?.mode == .handsFree)
        intent.update(cancel ? .cancel : .shortcutDown(.handsFree), at: 4)
        #expect(intent.claim(at: 5) == nil)
    }

    @Test("a retry claim is single-use and invalidated by physical input or a new attempt")
    func staleClaims() throws {
        var intent = MicrophoneRetryIntent()
        intent.begin(mode: .pushToTalk, at: 0)
        let claimed = intent.claim(at: 1)
        let old = try #require(claimed)
        #expect(intent.claim(at: 1) == nil)
        intent.update(.pushToTalkReleased, at: 2)
        #expect(intent.consume(old, at: 2) == nil)
        intent.begin(mode: .handsFree, at: 3)
        let fresh = intent.claim(at: 4)
        let current = try #require(fresh)
        #expect(intent.consume(old, at: 4) == nil)
        #expect(intent.consume(current, at: 4)?.mode == .handsFree)
        #expect(intent.consume(current, at: 4) == nil)
        #expect(intent.claim(at: 5) == nil)
        intent.rearm()
        #expect(intent.claim(at: 6) != nil)
    }

    @Test("another intent cannot consume a claim")
    func foreignClaim() throws {
        var first = MicrophoneRetryIntent()
        var second = MicrophoneRetryIntent()
        first.begin(mode: .handsFree, at: 0)
        second.begin(mode: .handsFree, at: 0)
        let candidate = first.claim(at: 1)
        let ticket = try #require(candidate)
        _ = second.claim(at: 1)
        #expect(second.consume(ticket, at: 1) == nil)
        #expect(first.consume(ticket, at: 1)?.mode == .handsFree)
    }
}
