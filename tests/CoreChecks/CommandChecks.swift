#if os(macOS)
import Foundation
import PhotoBridgeCore

func runCommandChecks() throws {
    let python = URL(fileURLWithPath: "/usr/bin/python3")
    let output = try BoundedCommand.run(executable: python, arguments: ["-c", "import sys; sys.stdout.write('x'*3000000); sys.stderr.write('z'*3000000)"], timeout: 5, outputLimit: 65_536)
    try require(output.exitCode == 0 && output.truncated && output.output.count == 65_536, "large child output is drained without unbounded retention or deadlock")
    let start = ProcessInfo.processInfo.systemUptime
    let blocked = try BoundedCommand.run(executable: python, arguments: ["-c", "import signal,time; signal.signal(signal.SIGTERM,signal.SIG_IGN); time.sleep(30)"], timeout: 0.2, terminationGrace: 0.2)
    try require(blocked.interruption == .timedOut && ProcessInfo.processInfo.systemUptime - start < 3, "unresponsive connection process has a bounded deadline even if TERM is ignored")
    let flag = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try Data().write(to: flag)
    defer { try? FileManager.default.removeItem(at: flag) }
    let stopped = try BoundedCommand.run(executable: python, arguments: ["-c", "import time;time.sleep(30)"], cancelFile: flag, cancellationGrace: 0.1, terminationGrace: 0.1)
    try require(stopped.interruption == .cancelled, "stalled transfer can stop after a graceful pause window")
    let normal = try BoundedCommand.run(executable: python, arguments: ["-c", "print('ready')"], timeout: 5)
    try require(normal.exitCode == 0 && normal.interruption == nil && String(data: normal.output, encoding: .utf8)?.contains("ready") == true, "normal command output and status are preserved")
}
#endif
