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
