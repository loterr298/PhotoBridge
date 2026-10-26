import Foundation
import PhotoBridgeCore

func runControlInboxChecks() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root.appendingPathComponent("Requests"), withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: root.appendingPathComponent("Responses"), withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let old = UUID().uuidString, pending = UUID().uuidString, huge = UUID().uuidString
    try Data("{}".utf8).write(to: root.appendingPathComponent("Requests/\(old).json"))
    try Data("{}".utf8).write(to: root.appendingPathComponent("Responses/\(old).json"))
    try Data("{\"id\":\"\(pending)\"}".utf8).write(to: root.appendingPathComponent("Requests/\(pending).json"))
    try Data(repeating: 32, count: 65_537).write(to: root.appendingPathComponent("Requests/\(huge).json"))
    let first = try ControlInbox.pending(in: root, ignoring: [])
    try require(first.requests.count == 1 && first.requests[0].id == pending, "control inbox skips responses and oversized requests")
    let second = try ControlInbox.pending(in: root, ignoring: first.responded)
    try require(second.responded.isEmpty && second.requests.count == 1, "immutable responses can be cached between scans")
    let symlink = UUID().uuidString
    try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("Requests/\(symlink).json"), withDestinationURL: root.appendingPathComponent("Requests/\(pending).json"))
    let third = try ControlInbox.pending(in: root, ignoring: [], limit: 1)
    try require(third.requests.count == 1 && third.requests[0].id == pending, "control request batch is bounded and symbolic links are rejected")
    let badRoot = root.appendingPathComponent("malformed")
    try FileManager.default.createDirectory(at: badRoot.appendingPathComponent("Requests"), withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: badRoot.appendingPathComponent("Responses"), withIntermediateDirectories: true)
    for n in 0..<8 {
        let id = String(format: "00000000-0000-4000-8000-%012d", n)
        try Data("{bad".utf8).write(to: badRoot.appendingPathComponent("Requests/\(id).json"))
    }
    let valid = "FFFFFFFF-FFFF-4FFF-8FFF-FFFFFFFFFFFF"
    try Data("{\"id\":\"\(valid)\"}".utf8).write(to: badRoot.appendingPathComponent("Requests/\(valid).json"))
    let badBatch = try ControlInbox.pending(in: badRoot, ignoring: [])
    let recovered = try ControlInbox.pending(in: badRoot, ignoring: badBatch.responded)
    try require(recovered.requests.contains(where: { $0.id == valid }), "eight malformed requests cannot starve later valid commands")
    try require((try FileManager.default.contentsOfDirectory(atPath: badRoot.appendingPathComponent("Responses").path)).filter { $0.hasSuffix(".json") }.count == 8, "malformed requests receive durable terminal failures")
    var activity = WorkActivity()
    activity.set("export", active: true); activity.set("import", active: true)
    activity.set("export", active: false)
    try require(activity.preventsIdle, "ending export does not release an active import")
    activity.foreground = false
    try require(!activity.preventsIdle, "background activity cannot keep screen awake")
    activity.foreground = true; activity.set("import", active: false)
    try require(!activity.preventsIdle, "idle screen releases display sleep prevention")
}
