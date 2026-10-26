#if os(macOS)
import Foundation
import Darwin

/// Runs off the main actor. Drains both output streams with bounded memory;
/// a stuck control call cannot leave the UI busy forever. Media commands have
/// no automatic duration limit; explicit pause gets a graceful boundary window.
public enum BoundedCommand {
    public enum Interruption: Equatable, Sendable { case timedOut, cancelled }
    public struct Result: Sendable {
        public let exitCode: Int32
        public let output: Data
        public let truncated: Bool
        public let interruption: Interruption?
    }
    public static func run(executable: URL, arguments: [String], timeout: TimeInterval? = nil,
                           outputLimit: Int = 1_048_576, cancelFile: URL? = nil,
                           cancellationGrace: TimeInterval = 10, terminationGrace: TimeInterval = 1) throws -> Result {
        guard outputLimit > 0, timeout.map({ $0.isFinite && $0 > 0 }) ?? true,
              cancellationGrace.isFinite, cancellationGrace >= 0,
              terminationGrace.isFinite, terminationGrace > 0 else { throw NSError(domain: "PhotoBridge.Command", code: 1, userInfo: [NSLocalizedDescriptionKey: "Invalid command bounds"]) }
        let process = Process(); let pipe = Pipe()
        process.executableURL = executable; process.arguments = arguments
        process.standardOutput = pipe; process.standardError = pipe
        process.standardInput = FileHandle.nullDevice
        let reader = pipe.fileHandleForReading
        defer { try? reader.close(); try? pipe.fileHandleForWriting.close() }
        let fd = reader.fileDescriptor
        guard fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK) != -1 else { throw CocoaError(.fileReadUnknown) }
        try process.run()
        try? pipe.fileHandleForWriting.close()
        let start = ProcessInfo.processInfo.systemUptime
        var cancellationAt: TimeInterval?; var terminatedAt: TimeInterval?
        var interruption: Interruption?; var output = Data(); var truncated = false
        var buffer = [UInt8](repeating: 0, count: 65_536)
        func drain() {
            // Bound each pass as well as retained bytes, so a noisy child cannot
            // starve the deadline/pause checks by continuously filling the pipe.
            for _ in 0..<16 {
                let count = Darwin.read(fd, &buffer, buffer.count)
                guard count > 0 else { return }
                let room = max(0, outputLimit - output.count)
                if count > room { truncated = true }
                output.append(contentsOf: buffer.prefix(min(count, room)))
            }
        }
        while process.isRunning {
            drain()
            let now = ProcessInfo.processInfo.systemUptime
            if cancellationAt == nil, let cancelFile, FileManager.default.fileExists(atPath: cancelFile.path) { cancellationAt = now }
            if terminatedAt == nil {
                if let timeout, now - start >= timeout { interruption = .timedOut }
                else if let cancellationAt, now - cancellationAt >= cancellationGrace { interruption = .cancelled }
                if interruption != nil { kill(process.processIdentifier, SIGTERM); terminatedAt = now }
            } else if now - terminatedAt! >= terminationGrace {
                kill(process.processIdentifier, SIGKILL)
            }
            var descriptor = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            _ = poll(&descriptor, 1, 40)
            if descriptor.revents & Int16(POLLHUP) != 0 { Thread.sleep(forTimeInterval: 0.01) }
        }
        process.waitUntilExit()
        drain()
        return Result(exitCode: process.terminationStatus, output: output, truncated: truncated, interruption: interruption)
    }
}
#endif
