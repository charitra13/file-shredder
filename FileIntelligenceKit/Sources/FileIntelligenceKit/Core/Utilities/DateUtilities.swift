import Foundation

public enum DateUtilities {
    /// SQLite stores dates with millisecond precision, so observations are truncated to match.
    public static func truncatedToMilliseconds(_ date: Date) -> Date {
        Date(timeIntervalSince1970: (date.timeIntervalSince1970 * 1_000).rounded(.down) / 1_000)
    }

    /// Compares dates allowing for the rounding introduced by storage.
    public static func approximatelyEqual(_ lhs: Date?, _ rhs: Date?, tolerance: TimeInterval = 0.002) -> Bool {
        switch (lhs, rhs) {
        case (nil, nil):
            return true
        case let (left?, right?):
            return abs(left.timeIntervalSince(right)) <= tolerance
        default:
            return false
        }
    }

    public static func wholeDays(from start: Date, to end: Date) -> Int {
        max(0, Int(end.timeIntervalSince(start) / 86_400))
    }
}
