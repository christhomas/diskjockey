import Foundation
import Testing

@testable import DiskJockeyLibrary

/// `ProcessRunner` exists to survive children that write more than a
/// pipe holds. These tests spawn children that do exactly that.
///
/// Every test here has a watchdog, because the failure mode under test
/// is a **hang**, not a wrong answer. Without one, a regression does not
/// fail the suite — it stops it, and a stalled test run reads as a slow
/// machine rather than a bug.
///
/// The suite is `.serialized` because its tests spawn subprocesses and
/// block threads waiting on them. Run in parallel with each other and
/// with the rest of the bundle, they starved neighbouring tests that
/// assert on 50-millisecond deadlines, and CI failed on *those* rather
/// than on anything here.
@Suite("ProcessRunner", .serialized)
struct ProcessRunnerTests {

    /// Comfortably past the ~64 KiB pipe buffer, small enough to stay
    /// fast. A child writing this much blocks unless something drains
    /// it.
    private static let floodBytes = 256 * 1024

    /// Run `body` on a background thread and fail if it does not finish.
    ///
    /// `Process` deadlocks do not throw and do not time out on their
    /// own, so the assertion has to come from outside.
    ///
    /// The work runs on a dedicated `Thread`, not the global queue. A
    /// deadline that can itself be starved of a thread reports a
    /// timeout for a test that was never given a chance to run — which
    /// is exactly what happened on CI, where all three of these
    /// reported the same 64 seconds.
    private func withDeadline<T: Sendable>(
        seconds: Double = 30,
        _ label: String,
        _ body: @escaping @Sendable () -> T
    ) -> T? {
        let box = LockedBox<T>()
        let done = DispatchSemaphore(value: 0)
        Thread.detachNewThread {
            box.value = body()
            done.signal()
        }
        if done.wait(timeout: .now() + seconds) == .timedOut {
            Issue.record("\(label) did not finish within \(seconds)s — the child is blocked writing to a pipe nobody is draining")
            return nil
        }
        return box.value
    }

    private func shell(_ script: String) -> Process {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", script]
        return p
    }

    @Test("a child that floods stdout is read to the end")
    func floodsStdout() {
        let n = Self.floodBytes
        let out = withDeadline("stdout flood") {
            try? ProcessRunner.run(
                self.shell("head -c \(n) /dev/zero | tr '\\0' 'a'"))
        }
        guard let out = out ?? nil else { return }
        #expect(out.stdout.count == n)
        #expect(out.status == 0)
    }

    /// The one the sequential drain gets wrong.
    ///
    /// Reading stdout to EOF and only then reading stderr works right up
    /// until the child fills stderr while the parent is still on stdout.
    /// Both streams flood here, so whichever the implementation reads
    /// second is the one that blocks the child.
    @Test("a child that floods both streams does not deadlock")
    func floodsBothStreams() {
        let n = Self.floodBytes
        let out = withDeadline("both-stream flood") {
            try? ProcessRunner.run(
                self.shell("""
                    head -c \(n) /dev/zero | tr '\\0' 'a' &
                    head -c \(n) /dev/zero | tr '\\0' 'b' >&2
                    wait
                    """))
        }
        guard let out = out ?? nil else { return }
        #expect(out.stdout.count == n)
        #expect(out.stderr.count == n)
        #expect(out.status == 0)
    }

    /// A stream nobody wants still needs somewhere to go.
    ///
    /// `runDiscardingOutput` uses `/dev/null`, which has no buffer to
    /// fill. An implementation that attached an unread `Pipe()` instead
    /// would hang here.
    @Test("output can be discarded without blocking the child")
    func discardsOutput() {
        let n = Self.floodBytes
        let status = withDeadline("discarded flood") {
            try? ProcessRunner.runDiscardingOutput(
                self.shell("""
                    head -c \(n) /dev/zero | tr '\\0' 'a'
                    head -c \(n) /dev/zero | tr '\\0' 'b' >&2
                    """))
        }
        guard let status = status ?? nil else { return }
        #expect(status == 0)
    }

    @Test("a failing child reports its status and its stderr")
    func reportsFailure() throws {
        let out = try ProcessRunner.run(shell("echo problem >&2; exit 3"))
        #expect(out.status == 3)
        #expect(out.stderrText.contains("problem"))
        #expect(out.stdout.isEmpty)
    }

    /// `diskutil` writes its failure reason to stdout, so callers that
    /// only surface stderr show an empty error. `combinedText` is what
    /// they use instead.
    @Test("combinedText carries a failure written to stdout")
    func combinesStreams() throws {
        let out = try ProcessRunner.run(shell("echo 'Unmount failed'; echo 'detail' >&2; exit 1"))
        #expect(out.status == 1)
        #expect(out.combinedText.contains("Unmount failed"))
        #expect(out.combinedText.contains("detail"))
    }

    @Test("a missing executable throws rather than reporting success")
    func missingExecutable() {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/nonexistent/definitely-not-here")
        #expect(throws: (any Error).self) {
            _ = try ProcessRunner.run(p)
        }
    }
}

/// A `Sendable` slot for carrying a result off a background thread.
private final class LockedBox<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: T?
    var value: T? {
        get { lock.lock(); defer { lock.unlock() }; return stored }
        set { lock.lock(); stored = newValue; lock.unlock() }
    }
}
