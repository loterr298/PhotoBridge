import Foundation

/// Stable ordering shared by the Mac preview and the direct iPhone import.
/// Numeric comparison keeps IMG_2 ahead of IMG_10 while the remaining
/// comparison stays case-insensitive and deterministic.
public enum MediaOrder {
    public static func sorted(_ names: [String]) -> [String] {
        names.sorted { lhs, rhs in
            let comparison = lhs.compare(rhs, options: [.numeric, .caseInsensitive, .widthInsensitive])
            if comparison == .orderedSame { return lhs < rhs }
            return comparison == .orderedAscending
        }
    }
}
