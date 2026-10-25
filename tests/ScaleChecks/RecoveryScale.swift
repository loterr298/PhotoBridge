import Foundation
import PhotoBridgeCore

func runRecoveryScale(_ count: Int) throws -> [String: Any] {
    let fm = FileManager.default
    let inbox = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try fm.createDirectory(at: inbox, withIntermediateDirectories: false)
    defer { try? fm.removeItem(at: inbox) }
    let sourceIDs = (1...count).map { "old-\($0)" }
    let plan = RestoreRecoveryPlan(inboxSessionID: inbox.lastPathComponent, manifestSHA256: String(repeating: "a", count: 64),
        requestSHA256: String(repeating: "b", count: 64), sourceAlbumID: "original-album", sourceAssetIDs: sourceIDs, title: "synthetic", allowTimestampRewrite: false)
    let store = try RestoreRecoveryStore.create(plan: plan, in: inbox)
    let digest = RestoreRecoveryStore.sha256(try Data(contentsOf: store.directory.appendingPathComponent("plan.json")))
    func event(_ kind: String, _ ordinal: Int, _ id: String?) throws {
        var value: [String: Any] = ["schemaVersion": "1.0.0", "attemptID": plan.attemptID, "planSHA256": digest, "kind": kind, "ordinal": ordinal]
        if ordinal > 0 { value["sourceID"] = sourceIDs[ordinal - 1] }
        if let id { value["createdID"] = id }
        if kind.hasSuffix("verified") { value["modified"] = 123456.0 }
        let filename = kind.hasPrefix("album-") ? kind + ".json" : String(format: "%06d-", ordinal) + kind.replacingOccurrences(of: "asset-", with: "") + ".json"
        try JSONSerialization.data(withJSONObject: value).write(to: store.directory.appendingPathComponent(filename), options: .withoutOverwriting)
    }
    // Synthetic fixtures bypass durable write fsync only while seeding the test data.
    // Replay below calls the production directory/file validation and JSON decoder.
    try event("album-intent", 0, nil); try event("album-placeholder", 0, "new-album")
    for i in 1...count {
        try autoreleasepool {
            try event("asset-intent", i, nil); try event("asset-placeholder", i, "new-\(i)"); try event("asset-verified", i, "new-\(i)")
        }
    }
    let start = Date()
    let state = try autoreleasepool { try store.state() }
    let seconds = Date().timeIntervalSince(start)
    try require(state.assetIDs == (1...count).map { "new-\($0)" }, "Ledger replay changed order")
    try require(state.verifiedVersions.count == count, "Ledger verification prefix incomplete")
    let middle = store.directory.appendingPathComponent(String(format: "%06d-placeholder.json", count / 2))
    let original = try Data(contentsOf: middle)
    var corrupted = try JSONSerialization.jsonObject(with: original) as! [String: Any]; corrupted["createdID"] = "new-1"
    try JSONSerialization.data(withJSONObject: corrupted).write(to: middle)
    try rejects("Duplicate identity in the middle must fail replay") { _ = try autoreleasepool { try store.state() } }
    try original.write(to: middle)
    let reopened = try RestoreRecoveryStore(in: inbox)
    try require(reopened.state().assetIDs.last == "new-\(count)", "Restart must retain the final identity")
    return ["ledgerAssets": count, "ledgerRecords": count * 3 + 2, "ledgerReplaySeconds": seconds,
        "ledgerChecks": "PASS ordered full replay, corrupt middle refused, fresh reopen stable", "photosTransactions": "NOT_RUN"]
}
