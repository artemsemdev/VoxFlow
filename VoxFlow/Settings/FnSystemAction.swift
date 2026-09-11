import Foundation

/// The action macOS performs when the Fn/Globe key is pressed by itself.
enum FnSystemAction: Equatable, Sendable {
    case doNothing
    case changeInputSource
    case emoji
    case startDictation
    case unknown

    typealias PreferenceRead = (_ key: CFString, _ applicationID: CFString) -> Any?

    var conflictName: String? {
        switch self {
        case .doNothing, .unknown: nil
        case .changeInputSource: "Change Input Source"
        case .emoji: "Show Emoji & Symbols"
        case .startDictation: "Start Dictation"
        }
    }

    @MainActor
    static func current(read: PreferenceRead = { key, applicationID in
        CFPreferencesCopyAppValue(key, applicationID)
    }) -> Self {
        guard let value = read("AppleFnUsageType" as CFString, "com.apple.HIToolbox" as CFString),
              let number = value as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID(),
              number.doubleValue == Double(number.intValue) else { return .unknown }
        return switch number.intValue {
        case 0: .doNothing
        case 1: .changeInputSource
        case 2: .emoji
        case 3: .startDictation
        default: .unknown
        }
    }
}
