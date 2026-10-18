import Foundation

/// "Delete history after" (design ST-05); 0 = keep forever.
public struct RetentionPolicy: Sendable, Equatable {
    public static let choices = [7, 30, 90, 365, 0]
    public static let `default` = RetentionPolicy(days: 30)
    public var days: Int
    public init(days: Int) { self.days = max(0, days) }
    public func cutoff(now: Date) -> Date? { days == 0 ? nil : now.addingTimeInterval(-Double(days) * 86_400) }
}
