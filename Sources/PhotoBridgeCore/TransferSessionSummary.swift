import Foundation

/// Normalizes the two on-disk journals used by iPhone staging and Mac USB transfer.
/// Missing totals remain zero so the UI cannot manufacture a percentage.
public struct TransferSessionSummary: Equatable, Identifiable {
    public let identifier: String
    public let status: String
    public let completed: Int
    public let total: Int
    public let bytes: Int64
    public let totalBytes: Int64
    public let currentResource: String?
    public let error: String?
    public let albumName: String?

    public init(identifier: String, status: String, completed: Int, total: Int,
                bytes: Int64, totalBytes: Int64, currentResource: String? = nil,
                error: String? = nil, albumName: String? = nil) {
        self.identifier = identifier; self.status = status; self.completed = completed; self.total = total
        self.bytes = bytes; self.totalBytes = totalBytes; self.currentResource = currentResource; self.error = error; self.albumName = albumName
    }

    public var id: String { identifier }
    public var fraction: Double {
        guard totalBytes > 0 else { return 0 }
        return min(1, max(0, Double(bytes) / Double(totalBytes)))
    }

    public static func decode(_ data: Data, identifier: String) throws -> TransferSessionSummary {
        struct Raw: Decodable {
            let status: String?
            let state: String?
            let resourcesCompleted: Int?
            let resourcesVerified: Int?
            let totalResources: Int?
            let bytesCompleted: Int64?
            let bytesVerified: Int64?
            let totalBytes: Int64?
            let currentResource: String?
            let error: String?
        }
        let raw = try JSONDecoder().decode(Raw.self, from: data)
        return TransferSessionSummary(identifier: identifier,
            status: raw.status ?? raw.state ?? "UNKNOWN",
            completed: raw.resourcesCompleted ?? raw.resourcesVerified ?? 0,
            total: raw.totalResources ?? 0,
            bytes: raw.bytesCompleted ?? raw.bytesVerified ?? 0,
            totalBytes: raw.totalBytes ?? 0,
            currentResource: raw.currentResource, error: raw.error)
    }
}
