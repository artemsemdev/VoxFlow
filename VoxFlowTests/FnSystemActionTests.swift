import Foundation
import Testing
@testable import VoxFlow

@Suite("Fn system action") @MainActor
struct FnSystemActionTests {
    @Test("AppleFnUsageType maps every documented preference value")
    func documentedValues() {
        let expected: [(Int, FnSystemAction, String?)] = [
            (0, .doNothing, nil),
            (1, .changeInputSource, "Change Input Source"),
            (2, .emoji, "Show Emoji & Symbols"),
            (3, .startDictation, "Start Dictation")
        ]

        for (value, action, name) in expected {
            let actual = FnSystemAction.current { key, applicationID in
                #expect(key as String == "AppleFnUsageType")
                #expect(applicationID as String == "com.apple.HIToolbox")
                return NSNumber(value: value)
            }
            #expect(actual == action)
            #expect(actual.conflictName == name)
        }
    }

    @Test("missing, malformed, and unrecognized values stay unknown")
    func unknownValues() {
        let values: [Any?] = [nil, -1, 4, "1", true, NSNumber(value: 1.5)]
        for value in values {
            #expect(FnSystemAction.current { _, _ in value } == .unknown)
        }
        #expect(FnSystemAction.unknown.conflictName == nil)
    }
}
