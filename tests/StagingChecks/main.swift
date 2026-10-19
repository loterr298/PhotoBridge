import Foundation
import PhotoBridgeCore

var checks = 0
func require(_ value: @autoclosure () throws -> Bool, _ message: String) throws {
    guard try value() else { throw ExportError.invalidManifest(message) }; checks += 1; print("PASS: \(message)")
}
func rejects(_ name: String, _ work: () throws -> Void) throws {
    var refused = false; do { try work() } catch { refused = true }; try require(refused, name)
}
let fm = FileManager.default
let root = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
try fm.createDirectory(at: root, withIntermediateDirectories: false)
defer { try? fm.removeItem(at: root) }
do {
    let descriptor = StagingResourceSource(resourceType: 1, originalFilename: "same.HEIC", uniformTypeIdentifier: "public.heic")
    let movie = StagingResourceSource(resourceType: 9, originalFilename: "same.MOV", uniformTypeIdentifier: "com.apple.quicktime-movie")
    func source(date: Date? = Date(timeIntervalSinceReferenceDate: 123456.1234567), resources: [StagingResourceSource]? = nil) -> StagingAssetSource {
        StagingAssetSource(identifier: "asset-a", modificationDate: date, creationDate: nil,
            pixelWidth: 10, pixelHeight: 20, mediaType: 1, mediaSubtypes: 8, resources: resources ?? [descriptor, movie])
    }
    let snapshot = OrderSnapshot(albumName: "test", albumIdentifier: "album-a", authorization: "full", fetchMode: "nil-options", identifiers: ["asset-a"], systemVersion: "fixture", build: "fixture")
    func fresh() throws -> (URL, StagingPlan, String) {
        let session = UUID().uuidString; let dir = root.appendingPathComponent(session)
        try fm.createDirectory(at: dir, withIntermediateDirectories: false)
        let plan = StagingPlan(sessionID: session, sourceOrder: snapshot, assets: [source()])
        let digest = try StagingResume.prepare(plan: plan, in: dir)
        return (dir, plan, digest)
    }
    let (old, plan, digest) = try fresh()
    let loaded = try StagingResume.load(in: old)
    try require(loaded.plan.assets == plan.assets && loaded.digest == digest, "lossless subsecond source metadata and plan binding")
    try plan.validateCurrent(albumIdentifier: "album-a", albumName: "test", assets: [source()])
    try require(true, "identical current source accepted")
    try rejects("subsecond edit change refused") { try plan.validateCurrent(albumIdentifier: "album-a", albumName: "test", assets: [source(date: Date(timeIntervalSinceReferenceDate: 123456.1234568))]) }
    try rejects("resource catalog change refused") { try plan.validateCurrent(albumIdentifier: "album-a", albumName: "test", assets: [source(resources: [movie, descriptor])]) }
    try rejects("different album refused") { try plan.validateCurrent(albumIdentifier: "other", albumName: "test", assets: [source()]) }
    try rejects("removed source member refused") { try plan.validateCurrent(albumIdentifier: "album-a", albumName: "test", assets: []) }
    try rejects("album rename cannot silently change frozen manifest") { try plan.validateCurrent(albumIdentifier: "album-a", albumName: "renamed", assets: [source()]) }
    let other = StagingAssetSource(identifier: "asset-b", modificationDate: source().modificationDate, creationDate: nil,
        pixelWidth: 10, pixelHeight: 20, mediaType: 1, mediaSubtypes: 8, resources: [descriptor])
    let twoOrder = OrderSnapshot(albumName: "test", albumIdentifier: "album-a", authorization: "full", fetchMode: "nil-options", identifiers: ["asset-a", "asset-b"], systemVersion: "fixture", build: "fixture")
    let twoPlan = StagingPlan(sessionID: UUID().uuidString, sourceOrder: twoOrder, assets: [source(), other])
    try rejects("same members in a different manual order refused") { try twoPlan.validateCurrent(albumIdentifier: "album-a", albumName: "test", assets: [other, source()]) }
    let nilPlan = StagingPlan(sessionID: UUID().uuidString, sourceOrder: snapshot, assets: [source(date: nil)])
    try rejects("missing edit version cannot authorize reuse") { try nilPlan.validateCurrent(albumIdentifier: "album-a", albumName: "test", assets: [source(date: nil)]) }
    let path = ResourcePaths.make(ordinal: 1, resourceIndex: 1, originalFilename: "same.HEIC")
    let file = old.appendingPathComponent(path); try fm.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data("abc".utf8).write(to: file)
    let receipt = try ProbeFiles.inspect(file)
    let r = ExportResource(resourceIndex: 1, resourceType: 1, originalFilename: "same.HEIC", uniformTypeIdentifier: "public.heic", storedRelativePath: path, sha256: receipt.sha256, byteCount: receipt.byteCount)
    try rejects("minimum integer ordinal rejected without arithmetic trap") { try StagingResume.record(r, ordinal: Int.min, plan: plan, digest: digest, in: old) }
    let badIndex = ExportResource(resourceIndex: Int.min, resourceType: 1, originalFilename: "same.HEIC", uniformTypeIdentifier: "public.heic", storedRelativePath: path, sha256: receipt.sha256, byteCount: receipt.byteCount)
    try rejects("minimum integer resource index rejected without arithmetic trap") { try StagingResume.record(badIndex, ordinal: 1, plan: plan, digest: digest, in: old) }
    try StagingResume.record(r, ordinal: 1, plan: plan, digest: digest, in: old)
    let partial = old.appendingPathComponent(ResourcePaths.make(ordinal: 1, resourceIndex: 2, originalFilename: "same.MOV") + ".part")
    try Data("unfinished".utf8).write(to: partial)
    let before = try fm.attributesOfItem(atPath: file.path)[.modificationDate] as? Date
    let partialBefore = try Data(contentsOf: partial)
    let reuse = try StagingResume.reusable(in: old, plan: plan, digest: digest)
    try require(reuse.count == 1 && reuse[path] == r, "only checkpointed complete resource reused; partial excluded")
    let (new, newPlan, newDigest) = try fresh()
    try StagingResume.copy(r, from: old, to: new)
    try StagingResume.record(r, ordinal: 1, plan: newPlan, digest: newDigest, in: new)
    try require(ProbeFiles.inspect(new.appendingPathComponent(path)).sha256 == receipt.sha256, "copied complete resource independently hashes correctly")
    try require((try fm.attributesOfItem(atPath: new.appendingPathComponent(path).path)[.referenceCount] as? NSNumber)?.intValue == 1, "reused copy retains one AFC-readable hard link")
    try require(try fm.attributesOfItem(atPath: file.path)[.modificationDate] as? Date == before && Data(contentsOf: partial) == partialBefore && Data(contentsOf: file) == Data("abc".utf8), "old bytes mtime and incomplete resource unchanged")
    try rejects("copy cannot overwrite a complete destination") { try StagingResume.copy(r, from: old, to: new) }
    try rejects("nested recovery cannot mutate old session") { try StagingResume.copy(r, from: old, to: old.appendingPathComponent("nested")) }
    try Data("abd".utf8).write(to: file)
    try rejects("corrupt cached resource refused before recovery") { _ = try StagingResume.reusable(in: old, plan: plan, digest: digest) }
    try Data("abc".utf8).write(to: file)
    let saved = root.appendingPathComponent("saved-resource")
    try fm.moveItem(at: file, to: saved)
    try rejects("missing checkpointed resource refused") { _ = try StagingResume.reusable(in: old, plan: plan, digest: digest) }
    try fm.moveItem(at: saved, to: file)
    let recordFile = old.appendingPathComponent("resource-records/000001-0001.json")
    let checkpointBytes = try Data(contentsOf: recordFile)
    let foreign = String(decoding: checkpointBytes, as: UTF8.self).replacingOccurrences(of: digest, with: String(repeating: "0", count: 64))
    try Data(foreign.utf8).write(to: recordFile)
    try rejects("checkpoint bound to different plan refused") { _ = try StagingResume.reusable(in: old, plan: plan, digest: digest) }
    try checkpointBytes.write(to: recordFile)
    try fm.removeItem(at: file); try fm.createSymbolicLink(at: file, withDestinationURL: new.appendingPathComponent(path))
    try rejects("symlink cached resource refused") { _ = try StagingResume.reusable(in: old, plan: plan, digest: digest) }
    let orphan = new.appendingPathComponent(ResourcePaths.make(ordinal: 1, resourceIndex: 2, originalFilename: "same.MOV"))
    try Data("uncheckpointed".utf8).write(to: orphan)
    try require(StagingResume.reusable(in: new, plan: newPlan, digest: newDigest).count == 1, "crash after commit before checkpoint causes reread, never unverified skip")
    try Data("{}".utf8).write(to: new.appendingPathComponent("album-order.json"))
    try rejects("completed staging session cannot be resumed") { _ = try StagingResume.load(in: new) }
    print("\(checks) staging recovery checks passed; synthetic only, device PhotoKit recovery NOT_RUN")
} catch { fputs("FAIL staging recovery: \(error)\n", stderr); exit(1) }
