import Foundation

/// An input-capable audio device. The CoreAudio UID survives reconnects and device-ID changes.
public struct AudioInputDevice: Identifiable, Sendable, Equatable {
    public let id: String
    public let name: String

    public init(id: String, name: String) {
        self.id = id
        self.name = name
    }
}
