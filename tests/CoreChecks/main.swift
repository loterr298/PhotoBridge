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
