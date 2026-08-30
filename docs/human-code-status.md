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
which it does on exit. Fixed at four sites in the app —
`MountTableParser.enumerate`, its zombie-unmount path, `RawDisksModel`, and
`FSKitMountService`, where **both** pipes are now drained because stderr can
fill on its own.

`diskutil list -plist` on a machine with many disks is comfortably past 64 KiB,
so this was not theoretical.

Three sites remain in `DiskJockeyAgent`, which is a separate unsandboxed helper;
they have the same defect and belong in a change scoped to that target.

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

51 tests pass, unchanged in number. The pipe-draining change has no unit test —
it needs a child that overflows the buffer, which is an integration concern; the
reasoning is recorded at each site instead.
