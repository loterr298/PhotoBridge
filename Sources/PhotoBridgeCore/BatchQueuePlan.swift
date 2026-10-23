import Foundation

public enum BatchQueueError: Error, LocalizedError {
    case empty
    case duplicate(String)
    public var errorDescription: String? {
        switch self {
        case .empty: return "至少选择一个相簿"
        case .duplicate(let identifier): return "相簿已重复选择：\(identifier)"
        }
    }
}

public struct BatchQueuePlan: Equatable {
    public let identifiers: [String]

    public init(identifiers: [String]) throws {
        guard !identifiers.isEmpty, !identifiers.contains(where: { $0.isEmpty }) else { throw BatchQueueError.empty }
        var seen = Set<String>()
        for identifier in identifiers where !seen.insert(identifier).inserted {
            throw BatchQueueError.duplicate(identifier)
        }
        self.identifiers = identifiers
    }
}
