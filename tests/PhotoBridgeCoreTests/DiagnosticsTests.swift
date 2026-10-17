import XCTest
@testable import PhotoBridgeCore

final class DiagnosticsTests: XCTestCase {
    // Removing order preservation or auto-passing an unread comparison must fail these tests.
    func testCapturePreservesAPIOrderRatherThanDatesOrNames() throws {
        let s = OrderSnapshot(albumName: "乱序", albumIdentifier: "album", authorization: "full",
                              fetchMode: "nil-options", identifiers: ["Z", "A", "M"],
                              creationDates: [Date(timeIntervalSince1970: 30), Date(timeIntervalSince1970: 10), nil],
                              systemVersion: "fixture", build: "test")
        XCTAssertEqual(s.members.map(\.localIdentifier), ["Z", "A", "M"])
        XCTAssertEqual(s.members.map(\.ordinal), [1,2,3])
        XCTAssertTrue(s.verification.hasPrefix("NOT_RUN"))
        XCTAssertFalse(try s.json().isEmpty)
    }
    func testComparisonRejectsMissingDuplicateAndMismatchedTwenty() throws {
        let ids = (1...20).map { "ID-\($0)" }
        XCTAssertTrue(try OrderComparison.compare(observed: ids, expected: ids).isEmpty)
        var moved = ids; moved.swapAt(2, 14)
        XCTAssertEqual(try OrderComparison.compare(observed: moved, expected: ids), [3,15])
        XCTAssertThrowsError(try OrderComparison.compare(observed: Array(ids.prefix(19)), expected: ids))
        XCTAssertThrowsError(try OrderComparison.compare(observed: ids, expected: Array(repeating: "same", count: 20)))
    }
    func testStaleThumbnailCallbacksAreRejected() {
        var generations = RequestGeneration()
        let old = generations.begin(); let new = generations.begin()
        XCTAssertFalse(generations.accepts(old))
        XCTAssertTrue(generations.accepts(new))
        generations.invalidate()
        XCTAssertFalse(generations.accepts(new))
    }
    func testProbeHashAndNoOverwrite() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("probe.bin")
        let receipt = try ProbeFiles.generate(at: url, byteCount: 1024 * 1024 + 7, origin: "test")
        XCTAssertEqual(receipt.byteCount, 1024 * 1024 + 7)
        XCTAssertEqual(try ProbeFiles.inspect(url).sha256, receipt.sha256)
        XCTAssertThrowsError(try ProbeFiles.generate(at: url, byteCount: 10, origin: "test"))
        let abc = dir.appendingPathComponent("abc"); try Data("abc".utf8).write(to: abc)
        XCTAssertEqual(try ProbeFiles.inspect(abc).sha256, "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
    }
}
