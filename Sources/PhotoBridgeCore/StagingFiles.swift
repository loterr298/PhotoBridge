import Foundation
import Darwin
public enum StagingFiles {
    /// Commit our own .part file without replacement or a second link (AFC rejects nlink > 1).
    public static func commit(part: URL, destination: URL) throws {
        guard part.isFileURL, destination.isFileURL,
              part.deletingLastPathComponent().standardizedFileURL == destination.deletingLastPathComponent().standardizedFileURL,
              part.lastPathComponent == destination.lastPathComponent + ".part",
              !part.path.contains("\0"), !destination.path.contains("\0") else {
            throw ExportError.invalidManifest("Commit requires an adjacent owned .part file")
        }
        let attributes = try FileManager.default.attributesOfItem(atPath: part.path)
        guard attributes[.type] as? FileAttributeType == .typeRegular,
              (attributes[.referenceCount] as? NSNumber)?.intValue == 1 else {
            throw ExportError.invalidManifest("Staging must be a regular file with exactly one hard link")
        }
        let handle = try FileHandle(forWritingTo: part)
        do { try handle.synchronize(); try handle.close() }
        catch { try? handle.close(); throw error }
        let code = part.path.withCString { source in
            destination.path.withCString { target in renamex_np(source, target, UInt32(RENAME_EXCL)) }
        }
        if code != 0 { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
    }
}
