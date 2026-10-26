import Foundation
import PhotoBridgeCore

func runConnectionChecks() throws {
    let first = UUID(), second = UUID(), third = UUID()
    var phone = PhoneConnection()
    let a = ConnectionRequest(nonce: first, confirmedNonce: nil)
    _ = phone.receive(a, now: 100, foreground: true)
    try require(!phone.isConnected(now: 100), "a one-way request cannot claim a confirmed connection")
    _ = phone.receive(ConnectionRequest(nonce: second, confirmedNonce: first), now: 103, foreground: true)
    try require(phone.isConnected(now: 103), "the Mac reading and confirming the phone reply connects both ends")
    _ = phone.receive(ConnectionRequest(nonce: second, confirmedNonce: first), now: 110, foreground: true)
    try require(!phone.isConnected(now: 111), "re-reading a persisted heartbeat cannot extend connection freshness")
    _ = phone.receive(ConnectionRequest(nonce: third, confirmedNonce: second), now: 112, foreground: true)
    try require(!phone.isConnected(now: 112), "a late confirmation after disconnect needs a fresh handshake")
    phone.invalidate()
    _ = phone.receive(ConnectionRequest(nonce: UUID(), confirmedNonce: third), now: 113, foreground: true)
    try require(!phone.isConnected(now: 113), "relaunch or foreground transition cannot reuse the old connection")
    var lease = ConnectionFreshness()
    lease.confirm(now: 10)
    try require(lease.isConnected(now: 17) && !lease.isConnected(now: 18) && !lease.isConnected(now: 9), "connection expires within eight seconds and rejects backward clocks")
    lease.invalidate()
    try require(!lease.isConnected(now: 11), "an explicit failed USB check clears the green state immediately")
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let file = root.appendingPathComponent("connection-request.json")
    try JSONEncoder().encode(a).write(to: file)
    try require(ConnectionRequest.read(in: root)?.nonce == first, "bounded connection metadata reads actual nonce")
    try Data("{partial".utf8).write(to: file)
    try require(ConnectionRequest.read(in: root) == nil, "partial USB heartbeat JSON is ignored")
    try Data(repeating: 32, count: 4097).write(to: file)
    try require(ConnectionRequest.read(in: root) == nil, "oversized connection metadata is rejected")
}
