import Foundation
import PhotoBridgeCore

var count = 0
func check(_ b: @autoclosure () throws -> Bool, _ name: String) throws {
    guard try b() else { throw ExportError.invalidManifest(name) }; count += 1; print("PASS: \(name)")
}
func rejects(_ name: String, _ f: () throws -> Void) throws { var failed = false; do { try f() } catch { failed = true }; try check(failed, name) }
let fm = FileManager.default
let root = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
try fm.createDirectory(at: root, withIntermediateDirectories: false)
defer { try? fm.removeItem(at: root) }
do {
    func fixture() throws -> RestoreRecoveryStore {
        let id = UUID().uuidString; let dir = root.appendingPathComponent(id)
        try fm.createDirectory(at: dir, withIntermediateDirectories: false)
        let plan = RestoreRecoveryPlan(inboxSessionID: id, manifestSHA256: String(repeating: "a", count: 64),
            requestSHA256: String(repeating: "b", count: 64), sourceAlbumID: "source-album", sourceAssetIDs: ["old-a", "old-b"],
            title: "new album", allowTimestampRewrite: false)
        return try RestoreRecoveryStore.create(plan: plan, in: dir)
    }
    let s = try fixture()
    try check(s.state().assetIDs.isEmpty, "new durable plan has no Photos objects")
    let lease = try s.lock()
    try rejects("second native writer lock refused") { _ = try s.lock() }
    lease.release(); let nextLease = try s.lock(); nextLease.release()
    try check(true, "native lock released for a later invocation")
    try s.beginAlbum()
    try rejects("album intent without placeholder is ambiguous, never recreated") { _ = try RestoreRecoveryStore(in: s.directory.deletingLastPathComponent()).state() }
    try s.recordAlbumPlaceholder("new-album")
    try check(s.state().albumID == "new-album", "durable album placeholder reconstructed after restart")
    try rejects("missing actual album does not authorize another album") { try s.state().validateObserved(albumID: nil, title: nil, memberIDs: [], visibleAssetIDs: []) }
    try rejects("wrong actual album refused") { try s.state().validateObserved(albumID: "other", title: "new album", memberIDs: [], visibleAssetIDs: []) }
    try s.state().validateObserved(albumID: "new-album", title: "new album", memberIDs: [], visibleAssetIDs: [])
    try s.beginAsset(ordinal: 1)
    try rejects("asset intent without placeholder is ambiguous, never recreated") { _ = try RestoreRecoveryStore(in: s.directory.deletingLastPathComponent()).state() }
    try s.recordAssetPlaceholder(ordinal: 1, identifier: "new-a")
    let pending = try s.state()
    try check(pending.assetIDs == ["new-a"] && pending.verifiedVersions.isEmpty, "committed-but-unverified explicit identity is preserved")
    try rejects("invisible recorded object never permits replay") { try pending.validateObserved(albumID: "new-album", title: "new album", memberIDs: [], visibleAssetIDs: []) }
    try rejects("visible object outside expected album refused") { try pending.validateObserved(albumID: "new-album", title: "new album", memberIDs: [], visibleAssetIDs: ["new-a"]) }
    try pending.validateObserved(albumID: "new-album", title: "new album", memberIDs: ["new-a"], visibleAssetIDs: ["new-a"])
    try check(true, "pending identity adopted only after actual album membership matches")
    try rejects("next create cannot precede prior resource verification") { try s.beginAsset(ordinal: 2) }
    let date = Date(timeIntervalSinceReferenceDate: 123456.1234567)
    try s.recordVerified(ordinal: 1, identifier: "new-a", modified: date)
    try check(s.state().verifiedVersions["new-a"] == date, "verified modification date keeps subsecond precision")
    try s.recordVerified(ordinal: 1, identifier: "new-a", modified: date)
    try rejects("changed verified asset version refused") { try s.recordVerified(ordinal: 1, identifier: "new-a", modified: date.addingTimeInterval(0.001)) }
    try rejects("existing intent cannot be overwritten or replayed") { try s.beginAsset(ordinal: 1) }
    try rejects("extreme negative ordinal is rejected without underflow") { try s.beginAsset(ordinal: Int.min) }
    try s.beginAsset(ordinal: 2)
    try rejects("source originals cannot be adopted as newly created copies") { try s.recordAssetPlaceholder(ordinal: 2, identifier: "old-b") }
    try rejects("duplicate newly-created identity refused before journal write") { try s.recordAssetPlaceholder(ordinal: 2, identifier: "new-a") }
    try s.recordAssetPlaceholder(ordinal: 2, identifier: "new-b")
    try rejects("reordered target membership refused") { try s.state().validateObserved(albumID: "new-album", title: "new album", memberIDs: ["new-b","new-a"], visibleAssetIDs: ["new-a","new-b"]) }
    try rejects("extra target member refused") { try s.state().validateObserved(albumID: "new-album", title: "new album", memberIDs: ["new-a","new-b","extra"], visibleAssetIDs: ["new-a","new-b"]) }
    try rejects("renamed target refused") { try s.state().validateObserved(albumID: "new-album", title: "renamed", memberIDs: ["new-a","new-b"], visibleAssetIDs: ["new-a","new-b"]) }
    try s.validateBinding(manifestSHA256: String(repeating: "a", count: 64), requestSHA256: String(repeating: "b", count: 64), allowTimestampRewrite: false)
    try rejects("changed manifest refused") { try s.validateBinding(manifestSHA256: String(repeating: "c", count: 64), requestSHA256: String(repeating: "b", count: 64), allowTimestampRewrite: false) }
    try rejects("permission cannot be silently broadened during recovery") { try s.validateBinding(manifestSHA256: String(repeating: "a", count: 64), requestSHA256: String(repeating: "b", count: 64), allowTimestampRewrite: true) }
    try rejects("changed USB request refused") { try s.validateBinding(manifestSHA256: String(repeating: "a", count: 64), requestSHA256: String(repeating: "c", count: 64), allowTimestampRewrite: false) }
    let reopened = try RestoreRecoveryStore(in: s.directory.deletingLastPathComponent())
    try check(reopened.state().assetIDs == ["new-a", "new-b"] && reopened.state().verifiedVersions["new-a"] == date,
        "fresh process ledger reconstruction retains pending identity and exact verified version")
    let firstRecord = s.directory.appendingPathComponent("000001-placeholder.json")
    let firstBytes = try Data(contentsOf: firstRecord)
    try rejects("exclusive commit never overwrites an existing mapping") { try RestoreRecoveryStore.writeNewMetadata(Data("{}".utf8), to: firstRecord) }
    try check(Data(contentsOf: firstRecord) == firstBytes && reopened.state().assetIDs.count == 2,
        "failed exclusive commit preserves final bytes and ignores retained uncommitted scratch")
    let missingIntent = s.directory.appendingPathComponent("000002-intent.json")
    let intentBytes = try Data(contentsOf: missingIntent); try fm.removeItem(at: missingIntent)
    try rejects("missing intent with recorded placeholder refuses recovery") { _ = try reopened.state() }
    try intentBytes.write(to: missingIntent)
    let record = s.directory.appendingPathComponent("000002-placeholder.json")
    let saved = try Data(contentsOf: record); try Data("{}".utf8).write(to: record)
    try rejects("corrupt journal never authorizes Photos creation") { _ = try s.state() }
    try saved.write(to: record)
    try fm.removeItem(at: record)
    try rejects("deleted placeholder is ambiguous after fresh reopen") { _ = try RestoreRecoveryStore(in: s.directory.deletingLastPathComponent()).state() }
    try saved.write(to: record)
    let linked = root.appendingPathComponent("linked-record")
    try fm.linkItem(at: record, to: linked)
    try rejects("hardlinked recovery record refused") { _ = try reopened.state() }
    try fm.removeItem(at: linked)
    try fm.removeItem(at: record); try fm.createSymbolicLink(at: record, withDestinationURL: s.directory.appendingPathComponent("000001-placeholder.json"))
    try rejects("symlink journal refused") { _ = try s.state() }
    print("\(count) Photos recovery checks passed; synthetic only, PhotoKit transaction recovery NOT_RUN")
} catch { fputs("FAIL recovery: \(error)\n", stderr); exit(1) }
