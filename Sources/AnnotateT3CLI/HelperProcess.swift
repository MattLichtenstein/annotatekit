#if os(macOS) || os(Linux)
import Foundation

/// Serializes subprocess startup with cancellation so quitting cannot launch a late delivery helper.
final class HelperProcess: @unchecked Sendable {
    private let lock = NSLock()
    private let process = Process()
    private var cancelled = false

    func run(executable: String, arguments: [String], capturesOutput: Bool) throws -> Bool {
        lock.lock()
        if cancelled { lock.unlock(); throw CancellationError() }
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        if capturesOutput { process.standardOutput = FileHandle.nullDevice }
        do { try process.run() }
        catch { lock.unlock(); throw error }
        lock.unlock()
        process.waitUntilExit()
        return process.terminationStatus == 0
    }

    func cancel() {
        lock.lock()
        defer { lock.unlock() }
        cancelled = true
        if process.isRunning { process.terminate() }
    }
}
#endif
