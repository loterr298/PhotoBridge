import Foundation

public struct OrderMember: Codable, Equatable, Identifiable {
    public var id: String { localIdentifier }
    public let ordinal: Int
    public let localIdentifier: String
    public let creationDate: Date?
    public init(ordinal: Int, localIdentifier: String, creationDate: Date? = nil) {
        self.ordinal = ordinal; self.localIdentifier = localIdentifier; self.creationDate = creationDate
    }
}

public struct OrderSnapshot: Codable, Equatable {
    public let schemaVersion: String
    public let albumName: String
    public let albumIdentifier: String
    public let authorization: String
    public let fetchMode: String
    public let capturedAt: Date
    public let systemVersion: String
    public let build: String
    public let members: [OrderMember]
    public let verification: String
    public init(albumName: String, albumIdentifier: String, authorization: String,
                fetchMode: String, identifiers: [String], creationDates: [Date?] = [],
                systemVersion: String, build: String, capturedAt: Date = Date()) {
        schemaVersion = "1.0.0"; self.albumName = albumName; self.albumIdentifier = albumIdentifier
        self.authorization = authorization; self.fetchMode = fetchMode; self.capturedAt = capturedAt
        self.systemVersion = systemVersion; self.build = build
        members = identifiers.enumerated().map {
            OrderMember(ordinal: $0.offset + 1, localIdentifier: $0.element,
                        creationDate: creationDates.indices.contains($0.offset) ? creationDates[$0.offset] : nil)
        }
        verification = "NOT_RUN: requires external Photos app manual comparison"
    }
    public func json() throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(self)
    }
}
