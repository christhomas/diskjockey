# Human-code findings — status

Tracks the **High** and **Medium** findings from
[`human-code-report-2026-08-28.md`](human-code-report-2026-08-28.md). The report
predates the work; this is the current position. Updated 2026-08-30.

**256 findings** — 16 High, 45 Medium, 16 Low across groups A (app), F (the
FSKit extension family) and G (cross-cutting). The largest set in the family by
some margin.

| | count |
|---|---|
| Fixed | 9 High |
| Still open | ~52 High/Medium |

---

## Fixed

### G1 / A4 — every `Process` call waited before draining its pipes — **fixed**

```swift
try proc.run()
proc.waitUntilExit()
let data = try? pipe.fileHandleForReading.readToEnd()
```

A child that writes more than the pipe buffer holds — roughly 64 KiB — blocks on
the write. A parent already inside `waitUntilExit()` never drains it. **Each
waits for the other, and the app hangs.**

Reading to EOF first cannot deadlock: EOF arrives when the child closes its end,
which it does on exit.

`diskutil list -plist` on a machine with many disks is comfortably past 64 KiB,
so this was not theoretical.

**Reading first turned out to be half of it, and the first round shipped the
other half in two forms.** Both are now fixed, along with every remaining site.

*One pipe read, the other left attached and unread.* `MountTableParser.enumerate`
and `RawDisksModel.runDiskutil` drained stdout before waiting — and set
`standardError = Pipe()`, which nothing read. A child blocked writing to a full
stderr never closes stdout, so the read that was meant to prevent the deadlock
blocks instead. An unread pipe is not a way of ignoring a stream; it is a 64 KiB
buffer that stops the child once it fills.

*Both pipes read, one after the other.* `FSKitMountService` drained stdout to EOF
and then stderr. If the child fills stderr while this side is blocked on stdout,
the same standoff happens one stream over — and which stream fills first depends
on the machine, so it would have looked intermittent.

The fix is one helper, `DiskJockeyLibrary/ProcessRunner.swift`, that drains both
concurrently and waits afterwards, plus `runDiscardingOutput` for a child whose
output is genuinely unwanted — that one uses `FileHandle.nullDevice`, which has
no buffer to fill.

**Two sites nobody had counted.** `AttachedDiskDetailView` runs `diskutil
unmount` and `fsck_fskit --progress`, both with `waitUntilExit()` before either
pipe is read. The second is the worst instance in the tree: `--progress` means
the child *streams*, writing a line per step for as long as the check runs, so
the buffer fills on any volume large enough to be worth checking.

**And the five in `DiskJockeyAgent`.** It is not a target in the Xcode project —
it is compiled standalone and links no framework of ours — so it carries its own
copy of the helper, with the reasoning duplicated in full so a change to one is
visibly a change to a decision. `hdiutil info -plist` lists every attached image
on the machine, and `diskprobe` emits a JSON description of a whole disk; both
were called with the wait first.

Six tests cover it, each with a watchdog, because the failure under test is a
**hang** rather than a wrong answer: without a deadline a regression stops the
suite instead of failing it, and a stalled run reads as a slow machine. Two of
them flood 256 KiB down both streams at once. Mutation-checked — reverting to the
sequential drain fails `a child that floods both streams does not deadlock` at
its deadline, and swapping `nullDevice` for an unread `Pipe()` fails
`output can be discarded without blocking the child` the same way.

**Two things about the tests came from CI failing, not from writing them.**

The suite is `.serialized`. Run in parallel with the rest of the bundle, these
tests spawn subprocesses and block threads waiting on them, and they starved
neighbouring tests that assert on 50-millisecond deadlines — so CI failed on
`DetachedOperationWatchdog` rather than on anything here.

And the watchdog itself runs its work on a dedicated `Thread` rather than the
global queue. A deadline that can be starved of a thread reports a timeout for a
test that was never given a chance to run: on CI all three flood tests reported
the *same* 64 seconds, which is what a starved pool looks like and not what a
deadlock looks like.

That fed back into `ProcessRunner` itself. It drained both pipes on background
threads and blocked the caller's, so every concurrent call held three. Only
stderr goes to another thread now; stdout is read on the calling thread, which
was already committed to waiting. Same guarantee, one blocked thread per call
instead of two.

### A1 — a protocol and a force-cast that existed only to trap each other — **fixed**

```swift
public var appLogger: AppLogger { appLogModel as! AppLogger }
```

`AppLogModel` does **not** conform to `AppLogger`, so this traps the moment
anything reads it. Searching the whole tree: `AppLogger` had **no conformers and
no callers** — the protocol and the property were each other's only reference.
Both removed.

### F1, F2, F4, F5, F6, F18 — the XFS/BTRFS extension family — **fixed earlier**

[#62](https://github.com/antimatter-studios/diskjockey/pull/62) for the botched
find-replace that left XFS and BTRFS sharing EROFS's item type and error text,
and [#69](https://github.com/antimatter-studios/diskjockey/pull/69) plus the
shared read-only volume support for the inherited capability flags — including
XFS shipping with `supportsJournal = false`.

---

## The largest remaining items

### F7 — NTFS declares 3 `FSMediaTypes` entries; every other extension declares more

A mismatch in what each extension claims it can mount. Worth checking against
what each driver actually supports before changing.

### F8, F9, F10 — six copies of one option parser, four-plus-two copies of a probe skeleton, one shape parameterised by the filesystem name

The same duplication the read-only volume work addressed for `statfs` and
capabilities, in the parts that were not covered. F10 is the biggest and the
most valuable.

### A2, A3, A5 — `@MainActor` methods doing subprocess work

`refresh()` synchronously forks `2N+1` processes on the main actor every three
seconds. G1 made each of those calls safe from deadlock; **it did not make them
cheap**, and this is the finding about the cost.

### The remainder

A6–A51, F11–F17, G2–G8 and the Medium and Low sets are recorded in the report
with locations and coverage notes.

---

## Verification

51 XCTest cases pass, unchanged in number, plus six new swift-testing cases for
`ProcessRunner` — the first coverage the pipe-draining behaviour has had. The
earlier round recorded the reasoning at each site and called a test an
integration concern; a child that floods a pipe turns out to be four lines of
`/bin/sh`.
