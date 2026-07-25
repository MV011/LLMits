import Foundation

/// Small utility to run external commands and capture stdout.
/// Used for discovery (ps, lsof, sqlite3) which must be off the main/cooperative threads.
enum ProcessRunner {
    /// Runs the command and returns trimmed stdout, or nil on failure/timeout.
    static func captureOutput(executable: String, arguments: [String]) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments

        let pipe = Pipe()
        process.standardOutput = pipe
        // Discard stderr: it is never drained, so a child writing more than
        // the pipe buffer (~64KB) would block on write and deadlock us.
        process.standardError = FileHandle.nullDevice

        guard (try? process.run()) != nil else { return nil }

        // Watchdog: terminate a runaway child instead of hanging forever in
        // readDataToEndOfFile()/waitUntilExit().
        let watchdog = DispatchWorkItem { process.terminate() }
        DispatchQueue.global().asyncAfter(deadline: .now() + 15, execute: watchdog)

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        watchdog.cancel()

        // .uncaughtSignal means the watchdog (or something else) killed it.
        guard process.terminationReason == .exit, process.terminationStatus == 0 else { return nil }
        return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}