import Foundation
import CryptoKit
import PhotoBridgeCore

func require(_ value: @autoclosure () throws -> Bool, _ message: String) throws {
    if try !value() { throw NSError(domain: message, code: 1) }; print("PASS: \(message)")
}
func rejects(_ name: String, _ work: () throws -> Void) throws {
    var rejected = false; do { try work() } catch { rejected = true }
    try require(rejected, name)
}
do {
    let progressData = Data("{\"status\":\"DOWNLOADING\",\"resourcesVerified\":2,\"totalResources\":4,\"bytesVerified\":20,\"totalBytes\":40,\"currentResource\":\"Resources/000003/0001.HEIC\"}".utf8)
    let progress = try TransferSessionSummary.decode(progressData, identifier: "session-1")
    try require(progress.identifier == "session-1" && progress.completed == 2 && progress.total == 4 && progress.bytes == 20 && progress.totalBytes == 40 && progress.fraction == 0.5, "transfer summary decodes real progress")
    let exportProgress = try TransferSessionSummary.decode(Data("{\"status\":\"EXPORTING\",\"resourcesCompleted\":3,\"bytesCompleted\":99}".utf8), identifier: "session-2")
    try require(exportProgress.completed == 3 && exportProgress.bytes == 99 && exportProgress.total == 0, "iPhone staging progress remains honest when totals are unknown")
    print("PASS: transfer summaries decode both Mac and iPhone journals")
} catch { fputs("FAIL transfer summary: \(error)\n", stderr); exit(1) }

do {
    let ids = (1...20).map { "ID-\($0)" }
    let snapshot = OrderSnapshot(albumName: "测试", albumIdentifier: "A", authorization: "full", fetchMode: "nil-options",
                                 identifiers: ids.reversed(), systemVersion: "synthetic", build: "local")
    try require(snapshot.members.first?.localIdentifier == "ID-20" && snapshot.members.last?.ordinal == 20, "API order preserved")
    try require(snapshot.verification.hasPrefix("NOT_RUN"), "reading never auto-verifies manual order")
    try require(!snapshot.json().isEmpty, "JSON encodes")
    try require(OrderComparison.compare(observed: ids, expected: ids).isEmpty, "20 identical positions")
    var moved = ids; moved.swapAt(2,14)
    try require(OrderComparison.compare(observed: moved, expected: ids) == [3,15], "moved positions detected")
    try rejects("19 members cannot pass") { _ = try OrderComparison.compare(observed: Array(ids.dropLast()), expected: ids) }
    try rejects("duplicate baseline cannot pass") { _ = try OrderComparison.compare(observed: ids, expected: Array(repeating: "X", count: 20)) }
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: false)
    defer { try? FileManager.default.removeItem(at: dir) }
    let file = dir.appendingPathComponent("probe.bin")
    let receipt = try ProbeFiles.generate(at: file, byteCount: 1024 * 1024 + 7, origin: "test")
    let readback = try ProbeFiles.inspect(file)
    try require(receipt.byteCount == readback.byteCount && receipt.sha256 == readback.sha256, "streamed hash and size round trip")
    try rejects("existing destination never overwritten") { _ = try ProbeFiles.generate(at: file, byteCount: 10, origin: "test") }
    try require(ProbeFiles.inspect(file).sha256 == receipt.sha256, "conflict preserves original bytes")
    let abc = dir.appendingPathComponent("abc"); try Data("abc".utf8).write(to: abc)
    try require(ProbeFiles.inspect(abc).sha256 == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad", "SHA-256 known vector")
    print("11 core checks passed; synthetic data only, device tests NOT_RUN")
} catch { fputs("FAIL: \(error)\n", stderr); exit(1) }

// A late callback from the previous photo must not replace the current thumbnail.
var generations = RequestGeneration()
let oldRequest = generations.begin()
let newRequest = generations.begin()
precondition(!generations.accepts(oldRequest), "stale thumbnail callback accepted")
precondition(generations.accepts(newRequest), "current thumbnail callback rejected")
generations.invalidate()
precondition(!generations.accepts(newRequest), "disappeared view accepted callback")
print("PASS: thumbnail request generations reject stale and disappeared callbacks")

// Export manifests must not certify incomplete bytes or silently change membership.
do {
    let source = OrderSnapshot(albumName: "synthetic", albumIdentifier: "album", authorization: "full",
        fetchMode: "nil-options", identifiers: ["a", "b"], systemVersion: "test", build: "test",
        capturedAt: Date(timeIntervalSince1970: 1_700_000_000))
    func resource(_ ordinal: Int, hash: String = String(repeating: "a", count: 64)) -> ExportResource {
        ExportResource(resourceIndex: 1, resourceType: 1, originalFilename: "same.HEIC", uniformTypeIdentifier: "public.heic",
            storedRelativePath: ResourcePaths.make(ordinal: ordinal, resourceIndex: 1, originalFilename: "same.HEIC"), sha256: hash, byteCount: 3)
    }
    func asset(_ ordinal: Int, id: String, resources: [ExportResource]) -> ExportAsset {
        ExportAsset(ordinal: ordinal, resourceGroupId: UUID().uuidString, sourceAssetLocalIdentifier: id,
            originalPhotoLibraryCreationDate: nil, pixelWidth: 10, pixelHeight: 10, mediaType: 1,
            mediaSubtypes: 0, resources: resources)
    }
    let assets = [asset(1, id: "a", resources: [resource(1)]), asset(2, id: "b", resources: [resource(2)])]
    let manifest = AlbumExportManifest(sessionID: UUID().uuidString, sourceOrder: source, assets: assets)
    try manifest.validate()
    try require(!manifest.json().isEmpty && manifest.restorationStatus.hasPrefix("NOT_RUN"), "export groups encode without claiming restore")
    try rejects("restore decode binds hash to exact decoded manifest bytes") {
        _ = try RestoreSafety.decodeManifest(data: manifest.json(), expectedSHA256: String(repeating: "0", count: 64))
    }
    try require(manifest.logicalTime(ordinal: 2).timeIntervalSince(manifest.logicalTime(ordinal: 1)) == 5, "logical times use five seconds without media rewrite")
    try require(ResourcePaths.make(ordinal: 1, resourceIndex: 1, originalFilename: "../../bad.weird!ext").hasSuffix(".bin"), "untrusted filename extension never enters path")
    try rejects("incomplete export groups cannot validate") {
        try AlbumExportManifest(sessionID: UUID().uuidString, sourceOrder: source, assets: [assets[0]]).validate()
    }
    try rejects("missing hash cannot validate") {
        try AlbumExportManifest(sessionID: UUID().uuidString, sourceOrder: source,
            assets: [asset(1, id: "a", resources: [resource(1, hash: "bad")]),assets[1]]).validate()
    }
    try rejects("member replacement cannot validate") {
        try AlbumExportManifest(sessionID: UUID().uuidString, sourceOrder: source,
            assets: [asset(1, id: "replacement", resources: [resource(1)]),assets[1]]).validate()
    }
    try rejects("empty resource group cannot validate") {
        try AlbumExportManifest(sessionID: UUID().uuidString, sourceOrder: source,
            assets: [asset(1, id: "a", resources: []),assets[1]]).validate()
    }
    print("8 export checks passed; synthetic only, PhotoKit export NOT_RUN")
} catch { fputs("FAIL export: \(error)\n", stderr); exit(1) }

// AFC on the target phone rejects multiply-linked files: native staging must leave one link.
do {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: false)
    defer { try? FileManager.default.removeItem(at: dir) }
    let final = dir.appendingPathComponent("original.bin")
    let part = final.appendingPathExtension("part")
    try Data("untouched bytes".utf8).write(to: part, options: .withoutOverwriting)
    try StagingFiles.commit(part: part, destination: final)
    let attributes = try FileManager.default.attributesOfItem(atPath: final.path)
    try require((attributes[.referenceCount] as? NSNumber)?.intValue == 1 && !FileManager.default.fileExists(atPath: part.path), "native commit leaves one AFC-readable hard link")
    try Data("new bytes".utf8).write(to: part, options: .withoutOverwriting)
    try rejects("native commit refuses existing destination") { try StagingFiles.commit(part: part, destination: final) }
    try require(Data(contentsOf: final) == Data("untouched bytes".utf8) && Data(contentsOf: part) == Data("new bytes".utf8), "failed commit preserves destination and partial bytes")
    let symlinkPart = dir.appendingPathComponent("symlink.bin.part")
    try FileManager.default.createSymbolicLink(at: symlinkPart, withDestinationURL: final)
    try rejects("native commit rejects symbolic links") { try StagingFiles.commit(part: symlinkPart, destination: dir.appendingPathComponent("symlink.bin")) }
    print("4 exclusive native commit checks passed")
} catch { fputs("FAIL native commit: \(error)\n", stderr); exit(1) }

// Restoration must reject changed files, duplicate replay and incomplete resource/order mappings.
do {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: dir.appendingPathComponent("Resources/000001"), withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    let path = "Resources/000001/0001.HEIC"; let file = dir.appendingPathComponent(path)
    try Data("abc".utf8).write(to: file)
    let r = ExportResource(resourceIndex: 1, resourceType: 1, originalFilename: "source.HEIC", uniformTypeIdentifier: "public.heic",
        storedRelativePath: path, sha256: "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad", byteCount: 3)
    try RestoreSafety.verifyResource(r, in: dir)
    try require(Data(contentsOf: file) == Data("abc".utf8), "restore verification reads untouched resource bytes")
    try Data("abd".utf8).write(to: file)
    try rejects("changed restore resource cannot pass") { try RestoreSafety.verifyResource(r, in: dir) }
    let linked = dir.appendingPathComponent("linked")
    try FileManager.default.createSymbolicLink(at: linked, withDestinationURL: dir)
    try rejects("restore rejects symbolic link ancestors") { try RestoreSafety.verifyResource(r, in: linked) }
    try RestoreSafety.claimOnce(in: dir)
    try rejects("restore never replays a prior Photos attempt") { try RestoreSafety.claimOnce(in: dir) }
    try require(RestoreSafety.sameResources(expected: [r, r], observed: [r, r]), "restore resource comparison retains duplicate multiplicity")
    try require(!RestoreSafety.sameResources(expected: [r, r], observed: [r]), "missing resource cannot be hidden by set comparison")
    try RestoreSafety.verifyOrder(sourceIDs: ["old-a", "old-b"], mapping: ["old-a": "new-x", "old-b": "new-y"], observed: ["new-x", "new-y"])
    try rejects("restore detects mapped order mismatch") {
        try RestoreSafety.verifyOrder(sourceIDs: ["old-a", "old-b"], mapping: ["old-a": "new-x", "old-b": "new-y"], observed: ["new-y", "new-x"])
    }
    try rejects("restore rejects duplicate new identifiers") {
        try RestoreSafety.verifyOrder(sourceIDs: ["old-a", "old-b"], mapping: ["old-a": "new-x", "old-b": "new-x"], observed: ["new-x", "new-x"])
    }
    print("8 restore safety checks passed; Photos import NOT_RUN")
} catch { fputs("FAIL restore: \(error)\n", stderr); exit(1) }

// Explicit permission can accept only a system edit timestamp, never other resource changes.
do {
    let original = try PropertyListSerialization.data(fromPropertyList: ["adjustmentTimestamp": Date(timeIntervalSince1970: 1000), "adjustmentData": Data([1,2,3]), "unknownVendorField": true], format: .xml, options: 0)
    let rewritten = try PropertyListSerialization.data(fromPropertyList: ["adjustmentTimestamp": Date(timeIntervalSince1970: 2000), "adjustmentData": Data([1,2,3]), "unknownVendorField": true], format: .xml, options: 0)
    func r(_ data: Data, type: Int = 7) -> ExportResource {
        ExportResource(resourceIndex: 1, resourceType: type, originalFilename: "edit.plist", uniformTypeIdentifier: "com.apple.property-list", storedRelativePath: "Resources/000001/0001.plist", sha256: SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined(), byteCount: data.count)
    }
    func compare(_ data: Data, allowed: Bool, type: Int = 7) throws -> ResourceRoundTripResult {
        try ResourceRoundTripComparison.verify(expected: [r(original, type: type)], observed: [r(data, type: type)],
            allowAdjustmentTimestampRewrite: allowed, loadOriginal: { _ in original }, loadObserved: { _ in data })
    }
    try rejects("edit timestamp rewrite requires explicit permission") { _ = try compare(rewritten, allowed: false) }
    let permitted = try compare(rewritten, allowed: true)
    try require(!permitted.strictBytesIdentical && permitted.authorizedAdjustmentTimestampDifferences == 1, "authorized timestamp difference never claims byte identity")
    let intact = try compare(original, allowed: false)
    try require(intact.strictBytesIdentical && intact.authorizedAdjustmentTimestampDifferences == 0, "unchanged resources retain strict byte result")
    let changedPayload = try PropertyListSerialization.data(fromPropertyList: ["adjustmentTimestamp": Date(timeIntervalSince1970: 2000), "adjustmentData": Data([1,2,4]), "unknownVendorField": true], format: .xml, options: 0)
    try rejects("opaque edit payload change is never authorized by time permission") { _ = try compare(changedPayload, allowed: true) }
    let changedType = try PropertyListSerialization.data(fromPropertyList: ["adjustmentTimestamp": Date(timeIntervalSince1970: 2000), "adjustmentData": Data([1,2,3]), "unknownVendorField": 1], format: .xml, options: 0)
    try rejects("unknown field boolean to integer change cannot pass") { _ = try compare(changedType, allowed: true) }
    try rejects("media resources never get adjustment timestamp exception") { _ = try compare(rewritten, allowed: true, type: 1) }
    try rejects("malformed plist cannot pass authorized comparison") { _ = try compare(Data("bad".utf8), allowed: true) }
    func duplicate(_ value: String, year: String, nested: Bool) -> Data {
        let dictionary = "<dict><key>payload</key><string>\(value)</string><key>payload</key><string>same</string></dict>"
        let payload = nested ? "<key>nested</key>" + dictionary : "<key>payload</key><string>\(value)</string><key>payload</key><string>same</string>"
        return Data(("<?xml version=\"1.0\"?><plist version=\"1.0\"><dict>" + payload + "<key>adjustmentTimestamp</key><date>\(year)-01-01T00:00:00Z</date></dict></plist>").utf8)
    }
    for nested in [false, true] {
        let before = duplicate("BAD", year: "2020", nested: nested)
        let after = duplicate("XYZ", year: "2026", nested: nested)
        try rejects(nested ? "nested duplicate keys cannot conceal changed payload" : "duplicate keys cannot conceal changed payload") {
            _ = try ResourceRoundTripComparison.verify(expected: [r(before)], observed: [r(after)], allowAdjustmentTimestampRewrite: true, loadOriginal: { _ in before }, loadObserved: { _ in after })
        }
    }
    let unknownBefore = Data("<plist version=\"1.0\"><dict><unknown>BAD</unknown><key>adjustmentTimestamp</key><date>2020-01-01T00:00:00Z</date></dict></plist>".utf8)
    let unknownAfter = Data("<plist version=\"1.0\"><dict><unknown>XYZ</unknown><key>adjustmentTimestamp</key><date>2026-01-01T00:00:00Z</date></dict></plist>".utf8)
    try rejects("unknown XML elements cannot conceal changed payload") {
        _ = try ResourceRoundTripComparison.verify(expected: [r(unknownBefore)], observed: [r(unknownAfter)], allowAdjustmentTimestampRewrite: true, loadOriginal: { _ in unknownBefore }, loadObserved: { _ in unknownAfter })
    }
    for leaf in ["<data>YQ==PAYLOAD</data>", "<date>2001-01-01T00:00:00ZPAYLOAD</date>"] {
        func scalar(_ payload: String, year: String) -> Data {
            Data(("<plist version=\"1.0\"><dict><key>payload</key>" + leaf.replacingOccurrences(of: "PAYLOAD", with: payload) + "<key>adjustmentTimestamp</key><date>\(year)-01-01T00:00:00Z</date></dict></plist>").utf8)
        }
        let before = scalar("BAD", year: "2020"); let after = scalar("XYZ", year: "2026")
        try rejects("ignored scalar text cannot conceal changed payload: \(leaf)") {
            _ = try ResourceRoundTripComparison.verify(expected: [r(before)], observed: [r(after)], allowAdjustmentTimestampRewrite: true, loadOriginal: { _ in before }, loadObserved: { _ in after })
        }
    }
    for (oldLeaf, newLeaf) in [("<date>2020-02-31T00:00:00Z</date>", "<date>2020-03-02T00:00:00Z</date>"),
                               ("<real>1e999</real>", "<real>2e999</real>"), ("<real>1e-999</real>", "<real>2e-999</real>")] {
        func scalar(_ leaf: String, year: String) -> Data {
            Data(("<plist version=\"1.0\"><dict><key>payload</key>" + leaf + "<key>adjustmentTimestamp</key><date>\(year)-01-01T00:00:00Z</date></dict></plist>").utf8)
        }
        let before = scalar(oldLeaf, year: "2020"); let after = scalar(newLeaf, year: "2026")
        try rejects("scalar normalization cannot conceal changed payload: \(oldLeaf)") {
            _ = try ResourceRoundTripComparison.verify(expected: [r(before)], observed: [r(after)], allowAdjustmentTimestampRewrite: true, loadOriginal: { _ in before }, loadObserved: { _ in after })
        }
    }
    print("15 authorized adjustment timestamp checks passed; device results require separate evidence")
} catch { fputs("FAIL timestamp policy: \(error)\n", stderr); exit(1) }

do {
    try runBatchChecks()
    print("3 batch queue checks passed")
} catch { fputs("FAIL batch queue: \(error)\n", stderr); exit(1) }

try runProgressChecks()
try runTransferDisplayChecks()

#if os(macOS)
try runCommandChecks()
#endif

try runControlInboxChecks()
try runConnectionChecks()
