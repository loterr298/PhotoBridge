import Foundation

/// Invalidates late asynchronous callbacks when a reusable thumbnail changes its asset.
public struct RequestGeneration {
    private var current: UUID?
    public init() {}
    public mutating func begin() -> UUID { let token = UUID(); current = token; return token }
    public mutating func invalidate() { current = nil }
    public func accepts(_ token: UUID) -> Bool { current == token }
}
