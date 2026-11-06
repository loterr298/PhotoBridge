import Foundation
import PhotoBridgeCore

func runProgressChecks() throws {
    try require(PhotoProgress(completed: 1, total: 50_000).completed == 1, "progress preserves single-photo counts")
    try require(PhotoProgress(completed: 49_999, total: 50_000).percent == 99, "percentage floors until verified completion")
    try require(PhotoProgress(completed: 20, total: 20).percent == 99, "all files copied is not final completion")
    try require(PhotoProgress(completed: 20, total: 20, finished: true).percent == 100, "verified completion is 100 percent")
    try require(PhotoProgress(completed: 0, total: 0).percent == nil, "unknown total does not invent a percentage")
    try require(PhotoProgress(completed: -1, total: 20).completed == 0, "negative progress is bounded")
    try require(PhotoProgress(completed: Int.max, total: Int.max).percent == 99, "large counts cannot overflow percentage")
    for value in [Double.nan, Double.infinity, -Double.infinity, Double.greatestFiniteMagnitude, Double(Int64.max), -1] {
        try require(ProgressNumber.nonnegativeInt64(value) == nil, "invalid numeric progress does not trap")
    }
    try require(ProgressNumber.nonnegativeInt64(123.9) == 123, "normal observed speed formats safely")
    try require(PhotoProgress(completed: 21, total: 20, finished: true).percent == 99, "out-of-range count cannot claim verified completion")
    for count in [29, 57, 58] {
        try require(PhotoProgress(completed: count, total: 100).percent == count, "integer percentage is exact at \(count)/100")
    }
    let latest = LatestPhotoCount()
    for count in 0...50_000 { latest.update(completed: count, total: 50_000) }
    try require(latest.read().completed == 50_000, "50001 updates retain one latest exact count")

    var display = ProgressDisplayState()
    try require(display.update(PhotoProgress(completed: 1, total: 100), operationID: "one"), "first progress sample is accepted")
    try require(!display.update(PhotoProgress(completed: 0, total: 100), operationID: "one"), "stale lower sample is rejected")
    try require(display.progress.completed == 1 && display.progress.total == 100, "stale lower sample cannot move displayed count backwards")
    try require(display.update(PhotoProgress(completed: 1, total: 100), operationID: "two"), "new operation resets progress identity")
    try require(display.progress.completed == 1 && display.progress.total == 100, "new operation starts from its own count")
    try require(display.update(PhotoProgress(completed: 2, total: 120), operationID: "two"), "growing scan total is accepted")
    try require(display.progress.completed == 2 && display.progress.total == 120, "growing totals remain truthful")

    let direct = DirectImportProgress(sessionID: "current", completed: 18, total: 6_304, phase: "IMPORTING")
    try require(direct.progress.completed == 18 && direct.progress.total == 6_304,
                "direct import owns the live iPhone counter")
    try require(direct.isActive, "direct import is active while PhotoKit is writing")
    let done = DirectImportProgress(sessionID: "current", completed: 6_304, total: 6_304, phase: "COMMITTED")
    try require(done.progress.finished, "direct import marks completion only after PhotoKit writes finish")

    let batches = DirectImportBatching.ranges(total: 258)
    try require(batches.map { Array($0) } == [Array(0..<128), Array(128..<256), Array(256..<258)],
                "direct import batches preserve every ordinal")

    try require(DirectOrderVerification.matches(expected: ["a", "b", "c"], actual: ["x", "a", "b", "c", "y"]),
                "direct import accepts the expected order inside an existing album")
    try require(!DirectOrderVerification.matches(expected: ["a", "b", "c"], actual: ["x", "a", "c", "b"]),
                "direct import rejects an order mismatch")
    try require(!DirectOrderVerification.matches(expected: ["a", "b", "b"], actual: ["a", "b", "b"]),
                "direct import rejects duplicate identifiers")
    try require(DirectCachePolicy.isOwnedSession("00000000-0000-0000-0000-000000000001"),
                "cache cleanup accepts a UUID session")
    try require(!DirectCachePolicy.isOwnedSession("../other"),
                "cache cleanup rejects path traversal sessions")
    try require(DirectCachePolicy.isOwnedRelativePath("DirectInbox/00000000-0000-0000-0000-000000000001/000001/photo.jpg"),
                "cache cleanup accepts an owned direct item")
    try require(!DirectCachePolicy.isOwnedRelativePath("Exports/other/photo.jpg"),
                "cache cleanup does not treat arbitrary paths as direct items")
}

func runTransferDisplayChecks() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let file = root.appendingPathComponent("display.json")
    let value = TransferDisplay(operationID: UUID().uuidString, direction: "TO_MAC", phase: "DOWNLOADING", completed: 17, total: 50_000, sessionID: "test", updatedAt: 1)
    try JSONEncoder().encode(value).write(to: file)
    try require(TransferDisplay.read(at: file)?.progress.completed == 17, "bounded USB display reads exact photo count")
    try require(value.presentationLabel(now: 100).hasPrefix("进度已保留"), "stale active progress is not shown as live")
    let done = TransferDisplay(operationID: value.operationID, direction: "TO_MAC", phase: "COMMITTED", completed: 20, total: 20, sessionID: "test", updatedAt: 1)
    try require(done.presentationLabel(now: 100).hasPrefix("上次传输"), "persisted completion is explicitly historical")
    let link = root.appendingPathComponent("link")
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: file)
    try require(TransferDisplay.read(at: link) == nil, "display reader rejects symbolic links")
    try Data(repeating: 32, count: 65_537).write(to: file)
    try require(TransferDisplay.read(at: file) == nil, "oversize display is rejected before decoding")
    try Data("{\"partial\":".utf8).write(to: file)
    try require(TransferDisplay.read(at: file) == nil, "in-flight partial UI metadata is ignored")
}
