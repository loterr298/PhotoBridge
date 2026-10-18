import Foundation
import PhotoBridgeCore

func require(_ value: @autoclosure () throws -> Bool, _ message: String) throws {
    if try !value() { throw NSError(domain: message, code: 1) }; print("PASS: \(message)")
}
func rejects(_ name: String, _ work: () throws -> Void) throws {
    var rejected = false; do { try work() } catch { rejected = true }
    try require(rejected, name)
}
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
