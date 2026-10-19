import Foundation
import Photos
import PhotoBridgeCore

enum PhotoOperationChecks {
    static var access: PhotoAccessState {
        switch PHPhotoLibrary.authorizationStatus(for: .readWrite) {
        case .authorized: return .full
        case .limited: return .limited
        case .denied: return .denied
        case .restricted: return .restricted
        case .notDetermined: return .notDetermined
        @unknown default: return .unknown
        }
    }
    static func requireFullAccess() throws { try OperationPreconditions.requireFullAccess(access) }
    static func availableCapacity(at directory: URL) throws -> Int64? {
        var url = directory
        url.removeAllCachedResourceValues()
        return try url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]).volumeAvailableCapacityForImportantUsage
    }
}
