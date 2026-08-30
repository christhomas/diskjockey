import Foundation

/// Run a child process and collect what it wrote, without deadlocking.
///
/// # The deadlock this exists to prevent
///
/// A pipe holds a bounded amount of data — roughly 64 KiB on macOS.
/// Once it is full, the child's next `write` blocks until somebody
/// drains it. So a parent that calls `waitUntilExit()` before reading
/// has arranged for each side to wait on the other:
///
/// ```swift
/// try proc.run()
/// proc.waitUntilExit()                       // waits for the child
/// let out = pipe.fileHandleForReading.readToEnd()   // never reached
/// ```
///
/// The child cannot exit until its output is read; the parent will not
/// read until the child exits. The app hangs, with no error and nothing
/// in a log.
///
/// # Reading first is not enough on its own
///
/// The obvious repair — read to EOF, then wait — fixes the single-pipe
/// case, and is still wrong with two pipes drained one after the other:
///
/// ```swift
/// let out = stdout.fileHandleForReading.readDataToEndOfFile()  // blocks
/// let err = stderr.fileHandleForReading.readDataToEndOfFile()  // unreached
/// ```
///
/// If the child fills `stderr` while the parent is blocked on `stdout`,
/// the same standoff happens one stream over. A child that writes a lot
/// to both — a progress stream on one and warnings on the other — hits
/// it, and which of the two fills first depends on the machine.
///
/// So both streams are drained **concurrently**, on their own queues,
/// and `waitUntilExit()` runs only once both have reached EOF. EOF
/// arrives when the child closes its end, which it does on exit, so no
/// ordering here can block.
///
/// # A stream nobody wants still needs a destination
///
/// Attaching a `Pipe()` to a stream and never reading it is the same
/// bug: the buffer fills and the child blocks. When the output is not
/// wanted, the answer is `FileHandle.nullDevice`, which has no buffer to
/// fill. `discardingOutput` does that.
public enum ProcessRunner {

    /// What a finished child left behind.
    public struct Output: Sendable {
        /// Everything the child wrote to stdout, to EOF.
        public let stdout: Data
        /// Everything the child wrote to stderr, to EOF.
        public let stderr: Data
        /// The child's exit status.
        public let status: Int32

        /// `stdout` decoded as UTF-8, or an empty string.
        public var stdoutText: String {
            String(data: stdout, encoding: .utf8) ?? ""
        }

        /// `stderr` decoded as UTF-8, or an empty string.
        public var stderrText: String {
            String(data: stderr, encoding: .utf8) ?? ""
        }

        /// Both streams, trimmed — for tools that report failures on
        /// stdout rather than stderr. `diskutil` is one: its "Unmount
        /// failed" lines come out on stdout.
        public var combinedText: String {
            (stdoutText + stderrText).trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    /// Launch `proc`, drain both streams to EOF, and wait for it.
    ///
    /// `proc.standardOutput` and `proc.standardError` are replaced with
    /// fresh pipes, so a caller cannot accidentally leave one attached
    /// to a buffer nothing reads.
    ///
    /// - Throws: whatever `Process.run()` throws — the executable is
    ///   missing, is not executable, or the fork failed.
    public static func run(_ proc: Process) throws -> Output {
        let outPipe = Pipe()
        let errPipe = Pipe()
        proc.standardOutput = outPipe
        proc.standardError = errPipe

        try proc.run()

        // Both readers start before either finishes. Draining them in
        // sequence would let a full stderr block the child while this
        // side is still reading stdout — the same deadlock, one stream
        // over.
        var outData = Data()
        var errData = Data()
        let group = DispatchGroup()
        let queue = DispatchQueue(label: "diskjockey.process-runner", attributes: .concurrent)

        queue.async(group: group) {
            outData = outPipe.fileHandleForReading.readDataToEndOfFile()
        }
        queue.async(group: group) {
            errData = errPipe.fileHandleForReading.readDataToEndOfFile()
        }
        group.wait()

        // Safe now: both pipes are at EOF, so nothing the child does can
        // block, and it has already closed its ends.
        proc.waitUntilExit()
        return Output(stdout: outData, stderr: errData, status: proc.terminationStatus)
    }

    /// Run `proc` with both streams sent to `/dev/null`.
    ///
    /// For a child whose output is genuinely not wanted. The point is
    /// that this is NOT the same as attaching pipes and ignoring them:
    /// `/dev/null` has no buffer to fill, so the child can write as much
    /// as it likes and still exit.
    ///
    /// - Returns: the child's exit status.
    /// - Throws: whatever `Process.run()` throws.
    @discardableResult
    public static func runDiscardingOutput(_ proc: Process) throws -> Int32 {
        proc.standardOutput = FileHandle.nullDevice
        proc.standardError = FileHandle.nullDevice
        try proc.run()
        proc.waitUntilExit()
        return proc.terminationStatus
    }
}
