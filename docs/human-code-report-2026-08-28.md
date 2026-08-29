# Human-code report — 2026-08-28

> **This document is analysis only.** No source file was modified, no branch was created,
> nothing was committed. Every entry below is a finding and a proposed fix, not a change
> that has been made. The working tree is exactly as it was found (branch `cth/chore-tasks`,
> with the two pre-existing untracked/modified `vendor/` entries left untouched).

---

## Scope

**Reviewed:** the Swift application source — 124 `.swift` files, 30,953 lines across
13 targets.

| Target | Files | Lines |
|---|---:|---:|
| `DiskJockeyApplication/` | 41 | 12,212 |
| `DiskJockeyLibrary/` | 33 | 4,396 |
| `DiskJockeyTests/` | 11 | 2,645 |
| `DiskJockeyFileProvider/` | 8 | 2,202 |
| `DiskJockeyEXT4/` | 8 | 3,137 |
| `DiskJockeyLibraryTests/` | 7 | 1,215 |
| `DiskJockeyNTFS/` | 3 | 2,142 |
| `DiskJockeyAgent/` | 3 | 263 |
| `DiskJockeySQUASHFS/` | 2 | 688 |
| `DiskJockeyBTRFS/` | 2 | 665 |
| `DiskJockeyXFS/` | 2 | 658 |
| `DiskJockeyEROFS/` | 2 | 656 |
| `DiskJockeyUITests/` | 2 | 74 |

Supporting non-Swift files were read where they define behaviour the Swift depends on:
the six FSKit extension `Info.plist` files, the seven `.entitlements` files, the six
bridging headers, `DiskJockey.xcodeproj/project.pbxproj`, and `scripts/install-agent-dev.sh`.

**Excluded entirely: `vendor/` and `build/`.** Neither directory was read, searched, or
analysed. `vendor/` is obsolete — the project has moved to sibling checkouts — and it
currently holds uncommitted changes belonging to someone else, so touching it would risk
both a wrong conclusion and a lost edit. `build/` is generated output. `.history/` (two
stale editor backups of `EXT4Backend.swift`, gitignored) was also excluded.

**Phases run:** Phase 0 (Understand), Phase 1 (Scan and Triage), Phase 3 (this report).
Phase 2 / the dev-loop was **not** run, by instruction. Nothing here has been implemented.

**Prior art:** `docs/human-code-report-2026-05-31.md` and `docs/human-code-report-2026-08-24.md`
both covered the Rust crates. This is the first sweep of the Swift side.

---

## Counts

**256 findings.** 0 fixed (analysis only). 0 skipped — everything found is listed.

| Severity | Count | Meaning |
|---|---:|---|
| **High** | 53 | Breaks under the sandbox, weakens a security boundary, or hides a real bug |
| **Medium** | 141 | Slows comprehension enough that a future change is likely to go wrong |
| **Low** | 62 | Cosmetic, or true but cheap |

By section:

| Section | Count |
|---|---:|
| 6. `DiskJockeyLibrary` | 61 |
| 4. Application — Views / Models | 51 |
| 5. Application — Services | 51 |
| 7. `DiskJockeyFileProvider` | 38 |
| 2. XPC and IPC boundaries | 18 |
| 3. FSKit extension family | 18 |
| 1. Sandbox | 11 |
| 8. `DiskJockeyAgent` | 8 |

By category:

| Category | Count |
|---|---:|
| Duplication | 37 |
| Dead / speculative code | 34 |
| Concurrency hazard | 32 |
| Misleading name | 28 |
| Lying / WHAT comment | 26 |
| Security | 22 |
| Magic numbers | 20 |
| Dense expression | 15 |
| God function | 11 |
| Sandbox violation | 9 |
| Missing test coverage | 8 |
| Too many params | 6 |
| XPC / IPC boundary clarity | 4 |
| Backend-independence violation | 3 |
| Deep nesting | 1 |

Coverage is thin where the risk is: **7 of ~40 public `DiskJockeyLibrary` types have
tests**, and `DiskJockeyFileProvider`, `DiskJockeyAgent`, `DiskJockeyXFS` and
`DiskJockeyBTRFS` have **none at all**. The tested set is almost exactly the seven types
produced by the 2026-06-02 structural refactor.

---

## Fix first

Seven items, in order. The first three are boundary and sandbox defects; the rest are the
duplication that will keep manufacturing new defects until it is collapsed.

**1. The app→agent XPC connection is unauthenticated, and the mach name is squattable.**
`DiskJockeyAgent/main.swift:13` correctly calls `setCodeSigningRequirement` on every
*incoming* connection. `DiskJockeyApplication/Services/DJAgentClient.swift:120-124` sets
**no** requirement on the *outgoing* one. The trust is one-directional. Since
`scripts/install-agent-dev.sh:18` registers `com.antimatterstudios.diskjockey.agent` from
`~/Library/LaunchAgents` — user-writable, no admin — any process running as the user can
claim that name, and the app will hand it `attachImage(atPath:)`, `detachDevice(_:)` and
`mountFSKit(...)`. Two lines to fix, and it is the only finding in this report where the
app actively hands work to an unverified peer. Related: the agent's own requirement string
omits `anchor apple generic`, so it is satisfiable by a self-signed leaf carrying the right
OU; and `DiskJockeyAgent` has **zero** references in `project.pbxproj`, so the entitlements
and signing that the requirement assumes are not reproducible from the repo.

**2. The sandboxed app target spawns subprocesses in eight places.**
`com.apple.security.app-sandbox` is `true` in `DiskJockeyApplication.entitlements`, yet
`Process()` runs `/sbin/mount`, `/usr/sbin/diskutil` (×3), `/sbin/fsck_fskit` and a bundled
`diskprobe` from three view/model files and one service file. Under the sandbox these fail;
at review they are fatal. The replacements already exist in-tree — `SwiftPartitionProbe`,
Disk Arbitration, `getfsstat`, and the agent — so these are unfinished migrations rather
than missing capability. `RawDisksModel.swift:11-14` carries a comment asserting the
opposite, which is what makes the pattern look sanctioned; it must go with the fix.

**3. The `RepairXPCService` name describes a boundary that deliberately isn't XPC.**
`DiskJockeyLibrary/DiskJockeyRepairProtocol.swift` argues at length, under a heading
literally titled "WHY NOT XPC", for file-based App-Group IPC — and then the name
`RepairXPCService` persists across five files including two actual filenames. An auditor
grepping `XPC` finds five hits and zero XPC; grepping for the real trust boundary (a
directory writable by every app-group member) finds nothing. Compounding it, the same file's
spec comment (`:40`, `:44`, `:184`) says results land at `<UUID>.result.json` while its own
`resultFilename(id:)` at `:196` produces `result-<UUID>.json`. A host written from the
comment never sees a result.

**4. `XfsVolume.swift` and `BtrfsVolume.swift` are `sed`-renamed copies of `ErofsVolume.swift`,
and the rename damaged them.** `XfsVolume.swift` vs `ErofsVolume.swift` differ by 58 lines
out of 722. Both new files still declare `private let items = FileIDCache<ErofsItem>()` and
cast `item as? ErofsItem` — so XFS, BTRFS and EROFS all share one phantom tag, voiding the
exact compile-time guarantee `FileSystemItem.swift:19-25` exists to provide. `XfsVolume.swift:6`
reads "every mutating op returns XFS", because the find-replace hit the errno name `EROFS`.
Both files inherited `supportsJournal = false` from EROFS — XFS is the journalled filesystem
this project has a whole log-writer for.

**5. The repair IPC client lives inside a SwiftUI view.**
`AttachedDiskDetailView.swift:597-710` writes the request file, spawns an uncancelled
`Task.detached` that captures the `View` struct, and polls for 30 minutes. Half of a
security boundary implemented in a view body, with a lifetime longer than the view's.

**6. Roughly 1,300 lines of the shared framework are unreachable.**
`DiskJockeyLibrary/Network/` (3 files, raw BSD sockets for the removed Go backend, zero
external references, one unconditional `as!` trap at `TCPListener.swift:82`) and
`DiskJockeyLibrary/Errors/` (4 enums, ~805 lines, verified zero external references by
word-boundary grep). Both still compile into a framework linked by six sandboxed targets.
`AppError.swift` (262 lines) and `MenuBarController.swift` in the app are likewise dead —
and `AppLogger` is worse than dead: `AppContainer.swift:21` force-casts to a protocol no
type conforms to, so `container.appLogger` traps on first access.

**7. `taskOption` and `buildFsCoreHandle` are duplicated six times.**
Byte-identical across all four read-only extensions (verified by diff), with a richer
variant in EXT4 and NTFS. Together with the ~300-line probe/load/unload skeleton, this is
the substrate that produced items 4 and 8. One `ReadOnlyFSKitModule` in `DiskJockeyLibrary`
parameterised on `(fsName, superOffset, superSize, magic, C symbol set)` would remove it.

---

## Findings

Severity: **H**igh / **M**edium / **L**ow. "Tests" names the file exercising the code, or
`none`.

### 1. Sandbox — code that cannot run under the MAS sandbox

| # | Location | Category | Sev | Finding / fix | Tests |
|---|---|---|---|---|---|
| S1 | `DiskJockeyApplication/Models/MountTableParser.swift:27-32` | Sandbox violation | H | `enumerate()` shells out to `/sbin/mount` and text-parses stdout. Replace with `getfsstat(2)` or `FileManager.mountedVolumeURLs(includingResourceValuesForKeys:)`. | `MountTableParserTests` (parser only, not the spawn) |
| S2 | `DiskJockeyApplication/Models/MountTableParser.swift:136-158` | Sandbox violation | H | `forceUnmountStale` spawns `/usr/sbin/diskutil unmount force`. Use `DADiskUnmount` or the agent. | none |
| S3 | `DiskJockeyApplication/Models/RawDisksModel.swift:260-271` | Sandbox violation | H | `runDiskutil` spawns `/usr/sbin/diskutil` from the sandboxed target. Route via `DJAgentClient` or DiskArbitration. | none |
| S4 | `DiskJockeyApplication/Views/AttachedDiskDetailView.swift:375-409` | Sandbox violation | H | `unmount(_:)` spawns `/usr/sbin/diskutil unmount` *from a SwiftUI view*. Move to `DADiskUnmount` and out of the view layer. | none |
| S5 | `DiskJockeyApplication/Views/AttachedDiskDetailView.swift:542-578` | Sandbox violation | H | `verify(_:)` spawns `/sbin/fsck_fskit --progress -t <fs> <dev>`. Reach `startCheck` without a subprocess — the App-Group request-file pattern `repair(_:)` already uses is right there at `:597`. | none |
| S6 | `DiskJockeyApplication/Services/FSKitMountService.swift:327-343` | Sandbox violation | H | `runDiskProbe` spawns a bundled `diskprobe` binary. `SwiftPartitionProbe` already does this in-process and is the only probe with tests. | `SwiftPartitionProbeTests` (covers the replacement, not this) |
| S7 | `DiskJockeyApplication/Services/FSKitMountService.swift:388-419` | Sandbox violation | H | Generic `run(executable:arguments:)` spawner with **zero callers** — dead code that teaches the next reader that shelling out is fine here. Delete. | none |
| S8 | `DiskJockeyLibrary/AppLog.swift:272-277` | Sandbox violation | M | When the app-group container is unreachable (missing entitlement on a new target — the likely real failure) the NDJSON sink silently falls back to `temporaryDirectory`, so logs vanish and the Logs panel is blank with no error. Log the fallback via `os_log` at error. | none |
| S9 | `DiskJockeyApplication.entitlements` | Sandbox violation | H | Declares `com.apple.security.temporary-exception.mach-lookup.global-name` for the agent. Temporary exceptions are routinely rejected at App Store review, and the whole `DJAgentClient` path depends on this one. Worth a decision before more code is built on it. | n/a |
| S10 | `DiskJockeyApplication/Models/RawDisksModel.swift:11-14` | Lying/WHAT comment | M | Header asserts subprocess polling works "under sandbox without entitlement gymnastics" and cites `AttachedDisksModel` as precedent. Both halves are false. This comment is what makes S3 look sanctioned. | n/a |
| S11 | `DiskJockeyApplication/Services/FSKitMountService.swift:350-366` | Dead/speculative | M | `locateDiskProbeBinary` walks eight parents from `#filePath` — ships the build machine's source layout in a release binary. Delete with S6. | none |

### 2. XPC and IPC boundaries

| # | Location | Category | Sev | Finding / fix | Tests |
|---|---|---|---|---|---|
| X1 | `DiskJockeyApplication/Services/DJAgentClient.swift:120-124` | Security | H | **No `setCodeSigningRequirement` on the outgoing connection.** The agent checks its callers; the app does not check the agent. Mach name is claimable from user-writable `~/Library/LaunchAgents` (`scripts/install-agent-dev.sh:18`). Mirror the agent's requirement string client-side. | none |
| X2 | `DiskJockeyAgent/main.swift:13-14` | Security | H | The requirement omits `anchor apple generic`, so it is satisfiable by an ad-hoc/self-signed peer whose leaf carries `subject.OU = 43UMKXZ8P4`. Prepend the anchor clause. | none |
| X3 | `DiskJockeyAgent/` (whole target) | Security | H | **Zero references in `DiskJockey.xcodeproj/project.pbxproj`.** The entitlements, hardened-runtime flags, signing identity and launchd `MachServices` registration that X1/X2 depend on are not reproducible from the repo. Commit the target. | none |
| X4 | `DiskJockeyAgent/AgentImpl.swift:131-157` | Security | H | `mountFSKit` composes a **root** shell line from four unvalidated XPC inputs and runs it via `NSAppleScript … with administrator privileges`, protected by two hand-rolled quoting layers (`shellQuote`/`appleScriptQuote` at `:215-222`). The quoting is correct today. Allowlist `fsType`, confine `mountPoint`, reject negative offsets, and prefer `/sbin/mount` with an argv array. Note it also has **no callers** (see V-D2) — the riskiest surface is unused. | none |
| X5 | `DiskJockeyAgent/AgentImpl.swift:10-38` | Security | H | `attachImage` attaches **any** caller-supplied path with no validation, canonicalisation or symlink check — a sandbox-escape primitive dressed as a convenience API. Require a security-scoped bookmark or user-selected path. | none |
| X6 | `DiskJockeyAgent/AgentImpl.swift:110-129` | Security | H | `detachDevice` passes `bsdName` to `hdiutil detach` unchecked, letting any peer force-detach volumes this agent never attached. Validate `^/dev/disk\d+(s\d+)?$` and cross-check ownership. (The *internal* caller at `:22-24` does validate — only the XPC entry point doesn't.) | none |
| X7 | `DiskJockeyAgent/AgentImpl.swift:215-222` | Missing coverage | H | `shellQuote`/`appleScriptQuote` are the only thing between XPC input and a root shell, and there is no test target for this component at all. Add one covering `' " \`, newline, `$(…)`, backtick. | none |
| X8 | `DiskJockeyLibrary/DiskJockeyRepairProtocol.swift:1-67` + `RepairWatcher.swift:12`, `MountableFileSystem.swift:14,101`, `OperationLock.swift:6,24`, `DiskJockeyEXT4/RepairXPCService.swift`, `DiskJockeyNTFS/RepairXPCService.swift` | XPC boundary clarity | H | The name `RepairXPCService` (two filenames + five comment sites) describes a mechanism the accompanying design doc argues *against* using. Rename to `RepairFileIPC`/`RepairFileWatcher` and drop "XPC" from the prose, so the real boundary — an App-Group directory writable by every group member — is the thing that gets audited. | `RepairWatcherTests` |
| X9 | `DiskJockeyLibrary/DiskJockeyRepairProtocol.swift:40,44,184` vs `:192,196` | Lying/WHAT comment | H | Spec comment says results are `<UUID>.result.json`; `resultFilename(id:)` produces `result-<UUID>.json`. Both processes are written against the code, so nothing is broken — but a third implementer following the comment silently never sees a result. | `RepairWatcherTests` (uses the API, not the comment) |
| X10 | `DiskJockeyApplication/Services/DJAgentClient.swift:131-136` | XPC boundary clarity | H | Error handler binds `error` and never reads it; nils `connection` without `invalidate()`, leaking the old connection and its `invalidationHandler`; no `interruptionHandler` at all. An agent crash surfaces as a generic proxy failure on the *next* call. | none |
| X11 | `DiskJockeyApplication/Services/DJAgentProtocol.swift` ≡ `DiskJockeyAgent/DJAgentProtocol.swift` | Duplication | M | Two byte-identical copies (verified: `diff` clean), hand-synced, invisible to the compiler. **No drift today.** Move into `DiskJockeyLibrary` and import from both sides so a signature change is a compile error, not a runtime decode failure. | none |
| X12 | `DiskJockeyAgent/DJAgentProtocol.swift:3-13` | XPC boundary clarity | M | Every method reports failure as a bare `String?`, forcing `extension String: @retroactive Error` at `AgentImpl.swift:7` and making callers substring-match agent prose. Return `NSError` with a DiskJockey domain. | none |
| X13 | `DiskJockeyAgent/main.swift:6-19` | XPC boundary clarity | L | `shouldAcceptNewConnection` always returns `true` with no logged reject path and no `invalidationHandler`, so a peer that fails the requirement is indistinguishable from one that never connected. | none |
| X14 | `DiskJockeyAgent/main.swift:3` | Magic numbers | L | Team ID `43UMKXZ8P4` is a bare source constant; a signing-team change breaks the boundary silently at runtime. Inject from a build setting. | none |
| X15 | `DiskJockeyApplication/Views/AttachedDiskDetailView.swift:597-710` | God function | H | The entire host-app half of the repair IPC — request encode, atomic write, response poll, timeout, decode, cleanup — lives in a SwiftUI `View`. Move to a `RepairCoordinator` on the model. | none |
| X16 | `DiskJockeyApplication/Views/AttachedDiskDetailView.swift:660-706` | Concurrency hazard | H | The response watcher is a `Task.detached` with a 30-minute budget that captures the `View` struct and the model, is never cancelled, and keeps writing `@State` after the user navigates away. Use `.task(id:)` or move it onto the model. | none |
| X17 | `DiskJockeyLibrary/DiskJockeyRepairProtocol.swift:139-154` | Missing coverage | M | `subdir(forFsType:)` enumerates ext4/ntfs/erofs/squashfs and lets **xfs and btrfs fall through to `default: nil`**, even though both extensions ship. The behaviour is right; nothing says so, and no test pins the table. | none |
| X18 | `DiskJockeyLibrary/AppLog.swift:112`, `DiskJockeyRepairProtocol.swift:134`, `NetworkFS/MountConfigStore.swift:30`, `NetworkFS/MountPolicy.swift:79`, `NetworkFS/MountKeychain.swift:30` | Duplication | M | The App Group identifier is a separate string literal in five types inside a framework linked by six targets. A rename half-lands. One `AppGroupPaths` type owning the identifier, the subdirectory names and identifier validation closes this and L-S2 together. | none |

### 3. The FSKit extension family — duplication and the divergence hiding in it

Six extensions, near-identical by construction. Pairwise diff of the four read-only
`*Volume.swift` files: EROFS↔XFS 58 differing lines, EROFS↔BTRFS 77, XFS↔BTRFS 77, out of
~360 lines each. For `*FileSystem.swift`: EROFS↔XFS 104, XFS↔BTRFS 104.

| # | Location | Category | Sev | Finding / fix | Tests |
|---|---|---|---|---|---|
| F1 | `DiskJockeyXFS/XfsVolume.swift:28,48,52,131,154,175,220,228,298` and `DiskJockeyBTRFS/BtrfsVolume.swift:28,48,52,140,163,184,229,237,307` | Misleading name | H | Both use `FileIDCache<ErofsItem>` and cast `as? ErofsItem`. There is no `XfsTag` or `BtrfsTag`. `FileSystemItem.swift:19-25` states the phantom tag exists so "cross-filesystem ID mix-ups become a compile error rather than a runtime corruption" — that guarantee is void for 2 of 6 filesystems, and the library's own doc comment is now false. Add the two tags. | `FileSystemItemTests` covers EXT4/NTFS tags only |
| F2 | `DiskJockeyXFS/XfsVolume.swift:6` and `DiskJockeyBTRFS/BtrfsVolume.swift:6` | Lying/WHAT comment | H | "every mutating op returns XFS" / "returns BTRFS" — the find-replace hit the **errno name** `EROFS` (read-only filesystem). The code correctly throws `POSIXError(.EROFS)`; the sentence is nonsense and hides that fact. | none |
| F3 | `DiskJockeyXFS/XfsVolume.swift:8` and `DiskJockeyBTRFS/BtrfsVolume.swift:8` | Lying/WHAT comment | M | Header still says "item identity is UInt64 (ErofsItem / ErofsTag)" in files for XFS and BTRFS. Symptom of F1. | none |
| F4 | `DiskJockeyXFS/XfsFileSystem.swift:34-36` | Lying/WHAT comment | H | Two contradictory comments stacked: "XFS superblock lives at byte offset 1024 and is 128 bytes long" (leftover EROFS) immediately followed by the correct "at byte offset 0, and is 264 bytes long", over `superOffset = 0, superSize = 264`. In a probe path, the wrong one is the one a reader trusts. | none |
| F5 | `DiskJockeyBTRFS/BtrfsFileSystem.swift:34-37` | Lying/WHAT comment | H | Same stale first line ("byte offset 1024 … 128 bytes") over `superOffset = 65536, superSize = 4096`. | none |
| F6 | `DiskJockeyXFS/XfsVolume.swift:62-63` and `DiskJockeyBTRFS/BtrfsVolume.swift:62-63` | Dead/speculative | H | Both inherited `supportsHardLinks = false` and `supportsJournal = false` from the EROFS copy. XFS is journalled (this project ships a full XFS log writer); both support hard links. Read-only mounts limit the blast radius, but a reader cannot tell which flags were *decided* and which were merely *inherited*. | none |
| F7 | `DiskJockeyNTFS/Info.plist` vs the other five | Duplication | H | NTFS declares **3** `FSMediaTypes` entries; EXT4, EROFS, SQUASHFS, XFS and BTRFS all declare the **same 52** (verified byte-identical), and NTFS's 3 are not a subset. NTFS is therefore not offered to `fskitd` for ~50 GPT partition-type GUIDs its siblings cover. One member of a copy-paste family left behind. | none |
| F8 | `taskOption<T>` at `DiskJockeyEROFS/…:225`, `SQUASHFS/…:237`, `XFS/…:227`, `BTRFS/…:225`, `EXT4FileSystem.swift:135`, `NTFSFileSystem.swift:61` | Duplication | H | Six copies of the same static parser for `key=value,key=value` task options. Move to `DiskJockeyLibrary`. | none |
| F9 | `buildFsCoreHandle` at `EROFS/…:237`, `SQUASHFS/…:253`, `XFS/…:239`, `BTRFS/…:237` (byte-identical, verified) plus richer variants at `EXT4Load.swift:425` and `NTFSFileSystem.swift:445` | Duplication | H | Four identical copies and two supersets. Extract the common core; let EXT4/NTFS layer container stacking on top. | none |
| F10 | `DiskJockeyEROFS/…:103`, `SQUASHFS/…:104`, `XFS/…:102`, `BTRFS/…:100` (`loadResource`, 108-118 lines each) | Duplication | H | The whole probe/load/unload/`startCheck` skeleton is one shape parameterised by `(fsName, superOffset, superSize, magic bytes, C symbol prefix)`. This is the substrate that produced F1-F6. A shared `ReadOnlyFSKitModule` base is the structural fix. | `ErofsVolumeTests`, `SquashfsVolumeTests` only |
| F11 | `DiskJockeySQUASHFS/SquashfsFileSystem.swift:59,63,65,68,73,74` | Magic numbers | M | Raw `96` (superblock size) appears six times, while the sibling EROFS/XFS/BTRFS files all extracted `superOffset`/`superSize` constants. The one member that didn't get the cleanup. | `SquashfsVolumeTests` |
| F12 | `DiskJockeyEROFS/…:128`, `SQUASHFS/…:132`, `XFS/…:127`, `BTRFS/…:125`, `NTFSFileSystem.swift:285` | Magic numbers | M | `BlockReadCache(maxEntries: 512)` repeated five times; `alignToPhysicalBlockSize: false` repeated six times (`NTFSFileSystem.swift:201,286` too). Both are *defaults* in `BlockDeviceContext.init` — and the default is now the minority choice at 1 of 6 call sites. EXT4 (`EXT4Load.swift:68`) alone passes neither and so gets no read cache. Flip the defaults or make them explicit everywhere. | `BlockReadCacheTests` (the cache, not its wiring) |
| F13 | `DiskJockeyLibrary/DeviceContexts.swift:88-96` | Lying/WHAT comment | M | The doc frames `readCache` and `alignToPhysicalBlockSize` as a binary EXT4-vs-NTFS choice ("NTFS opts in … EXT4 leaves nil"). Four more filesystems have since opted in. The prose is two filesystems behind the code. | none |
| F14 | `DiskJockeyApplication/Views/AttachedDiskDetailView.swift:466-475` | Duplication | M | `fsckArgFstype` lists `ext4`/`fsntfs`/`erofs`/`squashfs` and its comment says the read-only entries are there "for completeness/symmetry" — symmetry that xfs and btrfs were left out of. Same by-omission drift as X17. | none |
| F15 | `DiskJockeyEXT4/Info.plist` (`FSShortName = ext4`) vs the other five (`fsntfs`, `fserofs`, `fssquashfs`, `fsxfs`, `fsbtrfs`) | Misleading name | M | EXT4 is the only extension not following the `fs<name>` convention, which is why `subdir(forFsType:)` needs the asymmetric alias sets at `DiskJockeyRepairProtocol.swift:141-146`. | none |
| F16 | `DiskJockeyEXT4/RepairXPCService.swift:70-71` vs `DiskJockeyNTFS/RepairXPCService.swift:47-59` | Duplication | M | The EXT4 adapter passes `enterOperation`/`exitOperation` watchdog hooks and takes `opLock` before running; the NTFS adapter does neither. Inert today because NTFS returns "not implemented" immediately — a trap the moment NTFS repair lands. | `RepairWatcherTests` (the watcher, not the adapters) |
| F17 | All six `DiskJockey*/DiskJockey*-Bridging-Header.h` | Lying/WHAT comment | M | Every header points at `vendor/rust-fs-*` / `vendor/fs_*` for the source and static lib. The project has moved to sibling checkouts and `lib/`. Six comments now send readers to an abandoned tree. | n/a |
| F18 | `DiskJockeyXFS/`, `DiskJockeyBTRFS/` | Missing coverage | H | `ErofsVolumeTests` (15 cases) and `SquashfsVolumeTests` (15) exist; XFS and BTRFS have **none**, despite being the two files the copy-paste damaged. Cloning `ErofsVolumeTests` would have caught F1 and F6. | none |

### 4. DiskJockeyApplication — Views, Models, Components, Repositories

| # | Location | Category | Sev | Finding / fix | Tests |
|---|---|---|---|---|---|
| A1 | `Models/AppLogModel.swift:12-15` + `Services/AppContainer.swift:21` | Dead/speculative | H | `AppLogger` is declared; `AppLogModel` does **not** conform; `AppContainer.appLogger` does `appLogModel as! AppLogger`. Traps the moment anything touches it. Delete the protocol or conform. | none |
| A2 | `Models/RawDisksModel.swift:113-117` | Concurrency hazard | H | `refresh()` is `@MainActor` and synchronously forks `2N+1` processes (one `list` + one `info` per disk *and* per slice) every 3 s, blocking the main thread. Move the enumeration off-actor. | none |
| A3 | `Models/AttachedDisksModel.swift:299-300` | Concurrency hazard | H | `refresh()` is `@MainActor` and calls `MountTableParser.enumerate` — a subprocess plus one `statvfs` per mount — synchronously on every 3 s tick. | `AttachedDisksModelTests` (3 cases, not this path) |
| A4 | `Models/RawDisksModel.swift:267-270`; also `Models/MountTableParser.swift:32-34,144-147`, `Views/AttachedDiskDetailView.swift:384-394,551-563` | Concurrency hazard | H | `waitUntilExit()` is called **before** `readToEnd()`, so any child exceeding the ~64 KB pipe buffer deadlocks the child and hangs the caller forever. `MountTableParser.swift:144-147` is worst — stdout and stderr share one pipe. Drain concurrently before waiting. | none |
| A5 | `Models/AttachedDisksModel.swift:276,512,542` | Dead/speculative | H | `pendingEvents` is appended for every BSD that never materialises (whole-disk probes, unrecognised slices) and drained only by a matching mount. Unlike `pendingLogs` it has no cap and no eviction — unbounded growth over a long session. | `AttachedDisksModelTests` |
| A6 | `Views/AttachedDiskDetailView.swift:98-362` | God function | M | `body` is 264 lines: header, four error/success banners, three status banners, form, three sections, full toolbar, two confirmation dialogs. Extract `headerBar`, `banners`, `contentSections`, `detailToolbar`. | none |
| A7 | `Views/AttachedDiskDetailView.swift` (1,341 lines) | God function | M | The *file* is three files: a ~260-line view body, a ~330-line subprocess/IPC action layer (S4, S5, X15), and a ~400-line formatting-and-banner toolkit. | none |
| A8 | `Views/Mount/AddMountView.swift:489-597` | God function | M | `submit()` is 108 lines whose 8-arm switch inlines every protocol's argument list, reading 24 separate `@State` fields. Give each scheme a factory keyed off a per-scheme form model. | none |
| A9 | `Views/Mount/AddMountView.swift:19-91` | Too many params | M | 24 flat `@State` properties for 8 mutually-exclusive protocols: every field is live for every scheme and validation must re-derive which apply. Collapse into one enum with per-scheme payloads. | none |
| A10 | `Views/Mount/AddMountView.swift:275-291,342-360,410-427` | Duplication | M | `runDropboxSignIn`/`runGDriveSignIn`/`runOneDriveSignIn` are three same-shaped copies differing only in the coordinator call and which `@State` triple they write. | none |
| A11 | `Views/AttachedDiskDetailView.swift:1079-1091`, `Views/ContentView.swift:570-577`, `Views/IOStatsSection.swift:274-284`, `Views/RawDiskDetailView.swift:220-227`, `Views/DiskImageInspectorView.swift:441-447` | Duplication | M | **Five** independent byte formatters (`humanSize`, `formatBytes` ×2, `bytes`, `humanBytes`) that **disagree**: one keeps integer precision through KB, three only through B, and the inspector steps at 1500 instead of 2048 and drops the PB label. Highest-leverage dedup in the module. | none |
| A12 | `Views/RawDiskDetailView.swift:229-246` vs `Views/ContentView.swift:556-568` | Duplication | M | Two `prettyContent` tables returning **different strings for the same input** (`"(no filesystem)"` vs `"no filesystem"`, `"GPT (GUID Partition Table)"` vs `"GPT"`, `"Windows / NTFS / exFAT"` vs `"Windows / NTFS"`), so sidebar and detail pane describe the same disk differently. | none |
| A13 | `Views/Mount/DirectMountDetailView.swift:309-340` vs `Views/AttachedDiskDetailView.swift:1174-1206` | Duplication | M | `logRow`, `logLevelColor`, `rowTimestampFormatter` are exact copies. Extract a shared `LogLineRow`. | none |
| A14 | `Views/Mount/DirectMountDetailView.swift:462-476` vs `Views/ContentView.swift:310-324` | Duplication | M | `statusColor`/`statusLabel` duplicated verbatim. | none |
| A15 | `Views/AboutView.swift:5-35`, `Views/AboutPageView.swift:195-232`, `Views/HomeView.swift:301-316` | Duplication | M | `appIcon`/`appName`/`appVersion`/`appBuild`/`appBuildDate`/`buildTimestampFormatter` triplicated. Hoist one `AppMetadata`. | none |
| A16 | `Views/ContentView.swift:403-409` vs `Views/AttachedDiskDetailView.swift:901-904` | Duplication | M | Used-fraction calculation copied verbatim. Put it on `AttachedDisk` as `usedFraction`. | none |
| A17 | `Views/ContentView.swift:508,552-554`; also `Views/RawDiskDetailView.swift:66-68`, `Views/IOStatsSection.swift:72,80,107,220,228`, `Views/LogView.swift:172` | Misleading name | M | `Image(_:)` is the **asset-catalog** initializer but is fed SF Symbol names (`"externaldrive.badge.questionmark"`, `"internaldrive"`, `"checkmark.square.fill"`), which are not in `Assets.xcassets` (verified against all 46 imagesets) — those icons render as nothing. Use `Image(systemName:)` or the real `tabler-*` names. | none |
| A18 | `Views/AttachedDiskDetailView.swift:1279,1310` | Misleading name | M | `Image("tabler-alert-octagon-filled")` and `Image("tabler-alert-triangle-filled")` are not in the catalog (the real names are `tabler-xmark-octagon-fill` / `tabler-exclamationmark-triangle-fill`), so both repair banners render iconless. | none |
| A19 | `Views/AttachedDiskDetailView.swift:1229-1242` | Lying/WHAT comment | M | Two doc comments concatenated: the first eight lines describe `repairRecommendedBanner` (which lives at `:1307`) while sitting on `repairInProgressBanner`. | none |
| A20 | `Repositories/LogRepository.swift:25-26` | Lying/WHAT comment | M | Claims `suppressedScopes` is "persisted across launches via `@AppStorage` in the view layer". There is no `@AppStorage` for it anywhere — the filter resets every launch. | none |
| A21 | `Models/AppError.swift:172-219` | Misleading name | M | `==` matches on case only and ignores associated values, so `.mountFailed("disk busy") == .mountFailed("bad superblock")`. Any `removeDuplicates`/state-diff silently swallows a distinct failure. | none |
| A22 | `Models/AppError.swift:1-262` | Dead/speculative | M | The whole 262-line enum has zero references outside itself, and its `// MARK: - Backend Errors` block models a Go backend the architecture no longer has. | none |
| A23 | `Components/MenuBarController.swift:1-39` | Dead/speculative | M | Never instantiated; the `"ShowMainWindow"` notification it posts has no observer. | none |
| A24 | `Views/LogView.swift:109-148` | Dead/speculative | M | `LogRow` is a complete row view with no callers — `LogView` inlines its own at `:57-66`. | none |
| A25 | `Views/LogView.swift:10,68` | Dead/speculative | M | `refreshID` is initialised once and never reassigned, so `.id(refreshID)` pins the `List` identity permanently and buys nothing. | none |
| A26 | `Views/RawDiskDetailView.swift:18,24` | Dead/speculative | M | `attachedDisks` is `@ObservedObject`, assigned in `init`, never read — the view re-renders on every 3 s mount-table poll for nothing. | none |
| A27 | `Views/ContentView.swift:543-546` | Dead/speculative | M | `if disk.isWhole { return X }` followed by the identical unconditional `return X`. | none |
| A28 | `Views/ContentView.swift:456-466` | Dead/speculative | M | `dotColor` early-returns `.orange` for `isFsckRunning`, then the switch below handles `case .running: return .orange` again. | none |
| A29 | `Repositories/LogRepository.swift:66-73` | Misleading name | M | `exportLogs()` writes `logs.txt` into `temporaryDirectory`, swallows the error with `try?`, and never tells the user where it went — the Export button appears to do nothing. Use `NSSavePanel`. | none |
| A30 | `Views/AttachedDiskDetailView.swift:439-499`, `Models/AttachedDisksModel.swift:257-268`, `Models/DiskEventHandler.swift:48-53`, `Views/HomeView.swift:229-234,267` | Magic numbers | M | Filesystem type is a bare `String` with four spelling conventions (`ntfs`/`fsntfs`/`ntfs-fskit`, `erofs`/`fserofs`) re-hardcoded across five files — and they already disagree: `DiskEventHandler` yields `"ntfs"` while `verifySupported` only accepts `"fsntfs"`, so a `.mounting` NTFS row never shows Verify. Introduce one `FilesystemKind`. | `DiskEventHandlerTests` (23 cases) |
| A31 | `Views/AttachedDiskDetailView.swift:655-657,701` | Magic numbers | M | `60 * 30` and `0.5` declared inline mid-function, and the 30-minute figure restated as prose in the user-facing string — two places to drift. | none |
| A32 | `Models/AttachedDisksModel.swift:282` + `Models/RawDisksModel.swift:96` | Magic numbers | M | `pollInterval = 3.0` duplicated as an unexplained default; the two timers fire independently against the same devices. | none |
| A33 | `Views/AttachedDiskDetailView.swift:1150,1157`, `Views/Mount/DirectMountDetailView.swift:281`, `Models/AttachedDisksModel.swift:280` | Magic numbers | M | Bare `200` (tail length, twice), `minHeight: 200, maxHeight: 360`, and `logCap = 500` — the relationship between the display window and the retention cap is invisible. | none |
| A34 | `Views/DiskImageInspectorView.swift:97,409` vs `Views/HomeView.swift:159` | Duplication | M | `["raw", "vhd", "vmdk"]` written twice in one file and contradicted by HomeView, which advertises qcow2/VHDX as "always available". | none |
| A35 | `Models/AttachedDisksModel.swift:152-178` | Too many params | M | `AttachedDisk.init` takes 13 parameters, 10 defaulted — call sites are positional soup. Group the event-derived state. | `AttachedDisksModelTests` |
| A36 | `Views/IOStatsSection.swift:96-104` | Too many params | M | `throughputCard` takes 6 params that always travel together and must stay mutually consistent — the `peak`/`samples` invariant needs a 6-line warning at `:117-122` to survive. Pass one struct. | none |
| A37 | `Views/DiskImageInspectorView.swift:212-330` | God function | M | `partitionRow` is 118 lines. | none |
| A38 | `Views/ContentView.swift:70-160` | God function | M | `handleDroppedImages` is 90 lines and re-implements the probe sequence from `FSKitMountService` (see V21). | none |
| A39 | `Views/Mount/DirectMountDetailView.swift:16-19` | Lying/WHAT comment | L | "read the raw Go-side message" — that backend no longer exists; the detail comes from the FileProvider extension. | none |
| A40 | `Views/Mount/DirectMountDetailView.swift:5-6` | Lying/WHAT comment | L | "Parallel to `MountDetailView`" — no such type exists any more. | none |
| A41 | `DiskJockeyApp.swift:89-95,133-135` | Misleading name | L | Menu item is "Detach volume…" and the handler is generic, but the selector is `detachEXT4Volume`. | none |
| A42 | `DiskJockeyApp.swift:75-88` | Dead/speculative | L | The File menu offers only "Attach ext4 image…" and "Attach NTFS image…" although four more extensions ship. Use the auto-probing path the sidebar already uses. | none |
| A43 | `DiskJockeyApp.swift:35,198`; `Models/VendoredLibraryInfo.swift:150,153` | Lying/WHAT comment | L | `print(...)` bypasses `AppLog`, so these lines never reach the Logs pane the app ships. | none |
| A44 | `Models/VendoredLibraryInfo.swift:54` | Dense expression | L | The `split(whereSeparator:)` closure tests a `Character` for equality against the two-character literal `"\r\n"` — correct only because CR-LF is a single grapheme cluster, so it reads as a bug even though it isn't. Use `\.isNewline`. | none |
| A45 | `Models/AppError.swift:247` | Magic numbers | L | `case (NSCocoaErrorDomain, 4864)` with the name only in a trailing comment. Use `NSCoderReadCorruptError`. | none |
| A46 | `Models/AppError.swift:256-261` | Lying/WHAT comment | L | `userFriendlyMessage` returns `localizedDescription` and says so; no callers. | none |
| A47 | `Models/AppLogModel.swift:5-10` | Dead/speculative | L | `AppLogMessage` has no references anywhere — `messages` is `[LogEntry]`. | none |
| A48 | `Repositories/LogRepository.swift:35-37,41-48` | Dead/speculative | L | `logsPublisher()` and `visibleLogs` have no callers; the filtering the doc attributes to `visibleLogs` is actually done in `AppLogModel.swift:40-46`. | none |
| A49 | `Views/Mount/AddMountView.swift:586-587` | Misleading name | L | `@unknown default: throw POSIXError(.EINVAL)` surfaces as "the operation couldn't be completed". Name the unsupported scheme. | none |
| A50 | `Views/HomeView.swift:267` | Duplication | L | `["ext4", "ntfs", "erofs", "squashfs"]` re-listed three lines after the `filesystems` array holding the same keys. | none |
| A51 | `Views/AttachedDiskDetailView.swift:1079` | Misleading name | L | `humanSize` is `fileprivate` where the rest of the type is `private`, implying an external consumer that doesn't exist. | none |

### 5. DiskJockeyApplication — Services

| # | Location | Category | Sev | Finding / fix | Tests |
|---|---|---|---|---|---|
| V1 | `Services/FSKitMountService.swift:91-108` | Misleading name | H | `attach(imagePath:name:fsType:mountOptions:)` ignores `fsType` (log line only) and ignores `mountOptions` entirely, while the doc at `:85-90` promises the options are "passed verbatim to mount(8)" for partition slicing. The user's explicit "Mount as ext4 / Mount as NTFS" choice at `:598-605` is silently discarded and Disk Arbitration picks the driver. | none |
| V2 | `Services/FSKitMountService.swift:251-257` | Lying/WHAT comment | H | `runHdiutilAttach`/`runHdiutilDetach` no longer run hdiutil (they call `DJAgentClient`), and `runHdiutilAttach` drops its `imageURL` argument although `:141-143` documents that argument as the fd-inheritance trick letting hdiutil "read the file via our in-process security-scoped access". The described sandbox workaround does not exist. | none |
| V3 | `Services/DirectMountRegistry.swift:733-736` | Security | H | `persist()` JSON-encodes the whole `DirectMount` including `config` into app-group `UserDefaults` — for gdrive/onedrive that carries `clientSecret` + `cachedAccessToken` (a live bearer token), for S3 a `sessionToken`. The design intent at `:298-300` is that secrets live only in `MountKeychain`. Persist a credential-stripped projection. | none |
| V4 | `Services/OAuth/OAuthLoopbackListener.swift:99-107,348-362` | Concurrency hazard | H | `start()` returns the port **before** the unstructured `Task` installs the continuation, so a `finish(...)` in that window (notably `cancel()` from the coordinator's browser-open failure paths) tears the listener down while `continuation` is nil, and the later-installed continuation is never resumed — the awaiting task hangs to the 300 s timeout and `CheckedContinuation` reports a leak. | none |
| V5 | `Services/OAuth/OAuthCoordinator.swift:75-152,169-247,257-329` | Duplication | M | Three authorize flows repeat the same 40-line skeleton (PKCE, listener start, redirect URI, URLComponents, `NSWorkspace.open`, callback await, state compare) with only endpoint and params differing. | none |
| V6 | `Services/OAuth/OAuthCoordinator.swift:331-443` | Duplication | M | `exchangeOneDriveCode`/`exchangeGDriveCode`/`exchangeDropboxCode` are the same POST/status/decode body apart from URL and one form field — an error-handling fix has to be made three times. | none |
| V7 | `Services/OAuth/OAuthCoordinator.swift:139-141,237-239,319-321` | Concurrency hazard | M | On state mismatch the coordinator throws without `listener.cancel()`, leaving the bound loopback port and its 5-minute timeout work item alive. | none |
| V8 | `Services/OAuth/OAuthCoordinator.swift:272` vs `:90,:184` | Misleading name | M | OneDrive builds `redirect_uri` as `http://localhost:<port>` while Dropbox and GDrive use `http://127.0.0.1:<port>` against the same listener — "localhost" resolves to `::1` first on macOS, so this silently depends on the listener also accepting IPv6 loopback. | none |
| V9 | `Services/OAuth/OAuthLoopbackListener.swift:6-12` | Lying/WHAT comment | M | Header asserts "Loopback ports can't be hijacked by another app on the same machine; only the process that bound the port receives the callback". Any local process can connect and post a forged `?code=&state=` — which is precisely why the `state` guard exists. State the real property. | none |
| V10 | `Services/OAuth/OAuthLoopbackListener.swift:212-214` | Misleading name | M | A socket *receive* error is reported as `OAuthLoopbackError.bindFailed` ("Couldn't bind a local port…"), so a mid-flow read failure is diagnosed as a bind problem. | none |
| V11 | `Services/OAuth/PKCE.swift:31-40` | Lying/WHAT comment | M | Comment says the random source is "`SystemRandomNumberGenerator` via `Data` extension below"; there is no `Data` extension and the code is a hand-rolled per-byte `UInt8.random(in:)` loop. Use `SecRandomCopyBytes`. (The PKCE construction itself is correct — S256, 64-byte verifier.) | none |
| V12 | `Services/OAuth/OAuthRefreshSupervisor.swift:81` | Dense expression | M | `registry.mount(withID: UUID(uuidString: domainID) ?? UUID())` fabricates a random UUID on parse failure, making it indistinguishable from "mount was removed". | none |
| V13 | `Services/OAuth/OAuthRefreshSupervisor.swift:119-127` | Security | M | Re-auth writes the fresh `access_token` into the on-disk config plist via `configStore.save`, while `DirectMountRegistry`'s own persisted copy is never updated — a live token on disk *and* two copies immediately disagreeing. | none |
| V14 | `Services/OAuth/OAuthRefreshSupervisor.swift:89-92` | Concurrency hazard | M | The re-auth `Task` is never stored or cancelled and can outlive the mount (it awaits a browser round-trip with a 5-minute ceiling); `inFlight` is cleared only on the happy path. | none |
| V15 | `Services/DJAgentClient.swift:97-104` | Dead/speculative | M | `mountFSKit(...)` has **no callers** anywhere in the app, yet it is part of the exported XPC interface — the unsandboxed helper exposes a privileged, root-shell-composing mount entry point nothing uses (see X4). Remove from both protocol copies and `AgentImpl`. | none |
| V16 | `Services/DJAgentClient.swift:13-30` | Dead/speculative | M | `register()` is called at launch (`DiskJockeyApp.swift:36`) but its own comment states BTM will always reject registering an unsandboxed agent from a sandboxed app — a guaranteed no-op logging an error nobody can act on. | none |
| V17 | `Services/FSKitMountService.swift:59-77` | Dead/speculative | M | `FSKitError.mountPointInUse` and `.authorizationDenied` are never constructed — leftovers from the removed privileged-mount path. | none |
| V18 | `Services/FSKitMountService.swift:554-626` | God function | M | `attachUserPickedImage` probes, branches on multi-partition, resolves an fs type through a nested closure, runs a modal `NSAlert` driver picker, then launches the mount task — five responsibilities and two UI modals in one static function. | none |
| V19 | `Services/FSKitMountService.swift:641-676` vs `:165-189` | Duplication | M | `attachMultiPartition` re-derives the supported/skipped classification with a second, differently-spelled rule set (`ourKinds`/`appleKinds`/`containerSupportsApple`) that must stay in sync with the `switch part.fsKind` table in `attachAllPartitions`. They already disagree in shape. | none |
| V20 | `Services/FSKitMountService.swift:486-545` vs `Services/SwiftPartitionProbe.swift:141-150,245-303` | Duplication | M | `detectFSType` re-implements the container and ext4/NTFS magic sniffing `SwiftPartitionProbe` already owns, with its own copies of the QCOW2/VHDX/VMDK/conectix constants. | `SwiftPartitionProbeTests` covers the original only |
| V21 | `Services/FSKitMountService.swift:716-735` vs `Views/ContentView.swift:81-89` | Duplication | M | Three entry points, three probe strategies: this sequence, ContentView's copy of it, and `attachUserPickedImage`'s `Process`-based `runDiskProbe`. Funnel everything through one `probe(url:)`. | none |
| V22 | `Services/DirectMountRegistry.swift:264-366` | God function | M | `createMount` is a 100-line five-step ladder where every step hand-rolls the reverse-order rollback of all prior steps (`try? policyStore.delete` / `try? configStore.delete` repeated three times with growing prefixes). Adding a step means editing every later `catch`. Use a rollback stack. | none |
| V23 | `Services/DirectMountRegistry.swift:372-480` | Too many params | M | Eight `createXxxMount` factories take 6-10 positional parameters (`createS3Mount` takes ten, four of them defaulted `String`s) and every body is the same two lines — transposing `accessKeyID`/`secretAccessKey` compiles cleanly. | none |
| V24 | `Services/DirectMountRegistry.swift:554-570,594-598` | Dense expression | M | Both hot-path routers rebuild `Set(mounts.map { $0.domainID })` on **every** log line and extension event, so a chatty mount turns per-line routing into O(mounts) allocations on the main actor. | none |
| V25 | `Services/AppContainer.swift:60-63` | Lying/WHAT comment | M | Doc says extension state is "read (never written) via pluginkit", but `ExtensionStateService` explicitly abandoned pluginkit for FSKit's `FSClient` because pkd is sandbox-blocked (its own header says so). The comment points at a rejected, sandbox-illegal mechanism. | none |
| V26 | `Services/AppContainer.swift:78-157` | God function | M | `init()` builds ten services, wires two closure firehoses, starts an unstructured `Task`, sweeps symlinks and starts three pollers, with ordering constraints expressed only in prose ("Must be initialised AFTER attachedDisks"). | none |
| V27 | `Services/DiskArbitrationService.swift:50-71` | Concurrency hazard | M | DA callbacks capture `self` via `Unmanaged.passUnretained` then hop async (`Task { @MainActor in me.handleAppeared(disk) }`), so the service can deallocate between the C callback and the Task. `deinit` only unschedules the run loop and never calls `DAUnregisterCallback`. | none |
| V28 | `Services/LogTailService.swift:101-107` | Concurrency hazard | M | `handleLine` is already `@MainActor`-isolated yet wraps its three dispatches in `Task { @MainActor in … }`, deferring them to separate executor jobs with no ordering guarantee — log lines and their derived events can arrive out of order. | none |
| V29 | `Services/LogTailService.swift:136-169,63-77` | Concurrency hazard | M | `FileTail` has no `deinit` and no `stop()`: its `DispatchSourceFileSystemObject` is never cancelled and it owns the `FileHandle` whose fd the source watches, so dropping a tail closes the fd under a live source. `tails` is never pruned for deleted/rotated files and `dirSource` is never cancelled. | none |
| V30 | `Services/HomeAccessService.swift:126-130` | Security | M | `resolve()` calls `fileExists(atPath:)` **before** `startAccessingSecurityScopedResource()`, so a valid bookmark to an otherwise-unreadable folder reports "missing" and triggers `forget()` — silently destroying the user's granted access. | none |
| V31 | `Services/HomeAccessService.swift:145-147` | Lying/WHAT comment | M | "the sandbox only gates *writes*, and NSOpenPanel operates with a broader entitlement" — wrong on both halves. The sandbox gates reads too, and it is the powerbox grant, not an entitlement, that produces access. | none |
| V32 | `Services/HomeAccessService.swift:131-133` | Concurrency hazard | M | A stale bookmark is refreshed with `try? saveBookmark(for: url)` outside any scoped-access block and with the failure discarded, so the app re-does the stale dance every launch. | none |
| V33 | `Services/SwiftPartitionProbe.swift:168-169,198,206-209` | Magic numbers | M | The 512-byte logical sector size is hardcoded in five places across MBR and GPT parsing, so a 4Kn image is parsed at wrong offsets and silently yields garbage partitions rather than an error. | `SwiftPartitionProbeTests` (24 cases) |
| V34 | `Services/SwiftPartitionProbe.swift:194` | Magic numbers | M | `guard entrySize >= 128, entryCount > 0, entryCount <= 256` returns *no* partitions (indistinguishable from "no GPT") for a table declaring more than 256 entries, and 256 is unexplained. Clamp the iteration instead of discarding the table. | `SwiftPartitionProbeTests` |
| V35 | `Services/SwiftPartitionProbe.swift:128,171,219,239` | Magic numbers | M | The sniff window `0x9000` is repeated four times and re-clamped inside `sniffFS`, with no comment tying it to the ISO 9660 PVD at `0x8001` that dictates it. | `SwiftPartitionProbeTests` |
| V36 | `Services/ExtensionStateService.swift:41,59-63,80-97` | Magic numbers | M | A bare `pollInterval = 60` fires `refresh()`, which spawns an unstored, uncancellable `Task` doing an async `FSClient` call — overlapping refreshes are possible and nothing cancels in-flight work at teardown. | none |
| V37 | `Services/OAuthClientConfig.swift:92-102` + `OAuth/OAuthCoordinator.swift:381` | Security | M | The Google flow requires a non-empty `client_secret` read from a plaintext JSON resource inside the app bundle and POSTs it, so the "secret" ships to every user in cleartext. Documented but not bounded — assert the desktop-client profile in one place, or drop it if Google's installed-app profile permits. | none |
| V38 | `Services/OAuth/OAuthCoordinator.swift:49-50,354-356,392-394,429-431` + `OAuthRefreshSupervisor.swift:108` | Security | M | Token-endpoint failures embed the raw response body into `errorDescription`, which is then written into the shared app-group NDJSON on disk — provider response content lands in a plaintext file readable by every app-group member. Log status code plus a truncated body. | none |
| V39 | `Services/FSKitMountService.swift:306-308` | Dense expression | L | DA mount arguments are built with a hand-rolled `Unmanaged.passRetained("rw" as CFString)` into a nil-terminated array and released right after the call — an ownership dance resting on an undocumented assumption that DA copies its arguments. | none |
| V40 | `Services/FSKitMountService.swift:659` | Misleading name | L | A user-facing alert hardcodes a specific third-party tool invocation, against the project's reference-by-role convention. Describe the role only. | none |
| V41 | `Services/FSKitMountService.swift:7-18` | Lying/WHAT comment | L | Type doc claims mounting goes through "macOS 26's `mount -F` path" — no `mount` invocation remains, everything is Disk Arbitration — and runs into the `DiskProbeResult` doc with no blank line, so the struct's documentation is attached to the wrong subject. | none |
| V42 | `Services/SymlinkManager.swift:162-169` | Dead/speculative | L | `uniqueName` gives up after 999 attempts and returns a name known to collide, which `createSymlink` then resolves by deleting the existing symlink — a silent clobber at the end of what reads as a safety cap. | none |
| V43 | `Services/SymlinkManager.swift:69-79` | Dense expression | L | `symlinkExists` is called twice and mixed with an attribute check to decide the same thing. | none |
| V44 | `Services/SymlinkManager.swift:2-3,56,89,103` | Misleading name | L | Four comments name the target as `$HOME/diskjockey/<name>` although the directory is whatever the user picked (`suggestedFolderName` is only a suggestion). | none |
| V45 | `Services/SymlinkManager.swift:80-84` | Misleading name | L | Any `createSymbolicLink` failure is rewrapped as `SymlinkError.accessDenied`, so a name collision or I/O error is reported to the user as a permissions problem. | none |
| V46 | `Services/HomeAccessService.swift:95-99` | Dead/speculative | L | `pickFolder()` is a `@discardableResult` wrapper whose whole body is `let url = try promptUser(); return url`. | none |
| V47 | `Services/HomeAccessService.swift:176-185` | Duplication | L | `resolvedPath` re-implements bookmark resolution independently of `resolve()`, ignoring both the staleness flag and the corrupt-bookmark cleanup, so the displayed path can disagree with the path used. | none |
| V48 | `Services/DiskArbitrationService.swift:43-46` | Concurrency hazard | L | `DASessionCreate(kCFAllocatorDefault)!` force-unwraps in an initializer; the comment argues it can only fail catastrophically, but the crash lands on the user. | none |
| V49 | `Services/DiskArbitrationService.swift:250-255` | Misleading name | L | `canonicalFsName` strips *any* leading "fs" from DA's volume kind, so a filesystem whose real name starts with "fs" is silently renamed. | none |
| V50 | `Services/LogTailService.swift:127-131` | Dense expression | L | `parseISO8601` allocates a fresh `ISO8601DateFormatter` per log line on the main actor, in a path designed to absorb bursts. | none |
| V51 | `Services/DirectMountRegistry.swift:199-202` | Security | L | Registry init logs every persisted mount's scheme and `displayLocation` (host/user for ftp/sftp/smb) into the shared on-disk NDJSON at info level on every launch. | none |

### 6. DiskJockeyLibrary

| # | Location | Category | Sev | Finding / fix | Tests |
|---|---|---|---|---|---|
| L1 | `Network/TCPListener.swift:82` | Concurrency hazard | H | `pthread_kill(thread.threadDictionary["NSThreadID"] as! pthread_t, SIGINT)` force-casts a key that is **never set**, so `stopAccepting()` traps unconditionally. Signalling a thread to break `accept` is not a supported cancellation mechanism either. | none |
| L2 | `Network/TCPSocket.swift`, `Network/TCPConnection.swift`, `Network/TCPListener.swift` (whole directory) | Dead/speculative | H | Raw BSD sockets to 127.0.0.1 — the old Go-backend IPC. **Zero references anywhere outside itself** (verified). Still compiles into a framework loaded by three sandboxed extensions, and would need a network entitlement to work. Delete. | none |
| L3 | `Errors/BackendError.swift`, `Errors/DiskJockeyError.swift`, `Errors/MountError.swift`, `Errors/DiskTypeError.swift` (~805 lines) | Dead/speculative | H | All four enums plus `DiskTypeState` verified to have **zero** external references by word-boundary grep. Pure compile cost, and a trap for anyone who assumes they are the shared error vocabulary. | none |
| L4 | `IOStats/IOStatsRecorder.swift:100-101,119-135,199-218` | Concurrency hazard | H | `timer` and `lastEmitted` are unguarded `var`s on an `@unchecked Sendable` class: `stop()` mutates `timer` and calls `flush(force:)` on the caller's thread while a timer tick concurrently touches `lastEmitted` on `queue` — a real data race on the mount teardown path. | none |
| L5 | `Errors/BackendError.swift:202-247` | Misleading name | H | Hand-written `==` matches on case only, so `.operationFailed("disk full") == .operationFailed("permission denied")`. Any test or dedup built on it silently passes. | none |
| L6 | `NetworkFS/GDriveMountConfig.swift:30`, `OneDriveMountConfig.swift:27`, `S3MountConfig.swift:44` | Security | H | Live bearer credentials — `cachedAccessToken` for two OAuth providers, an STS `sessionToken` for S3 — are persisted in cleartext in the app-group plist while the sibling refresh token is correctly kept in the keychain. | none |
| L7 | `NetworkFS/MountConfigStore.swift:52-54`, `NetworkFS/MountPolicy.swift:98-100` | Security | H | `domainID` is interpolated straight into `appendingPathComponent("\(domainID).plist")` with no validation, so an identifier containing `../` reads or writes outside the app-group subdirectory. | none |
| L8 | `NetworkFS/S3MountConfig.swift:24-64`, `FTPMountConfig.swift:11-29`, `SFTPMountConfig.swift:14-32`, `SMBMountConfig.swift:14-31`, `WebDAVMountConfig.swift:19-34` vs `DropboxMountConfig.swift:66-70`, `GDriveMountConfig.swift:49-55`, `OneDriveMountConfig.swift:52-58` | Duplication | H | Three of eight configs have hand-written lenient decoders; five rely on synthesized `Codable`. So "add a field" is safe for Dropbox/GDrive/OneDrive and **destroys every persisted FTP/SFTP/SMB/WebDAV/S3 mount**. S3 with eight fields is the worst exposure. This is the family's real divergence — not the field sets. | none |
| L9 | `NetworkFS/FTPMountConfig.swift:20-23` vs `S3MountConfig.swift:52` | Security | H | `ftps: Bool = false` means the default FTP mount sends the keychain password over a cleartext control channel, while the sibling S3 config defaults `secure: Bool = true`. Make the safe choice the default across all eight. | none |
| L10 | `NetworkFS/` (all 8 configs + `NetworkFSPersonality.swift:47-58`) | Missing coverage | H | The `mountJSON` key sets and the `driverType` 1-8 integers are the entire ABI to the drivers — marked "DO NOT change these" — and not one line is covered. A typo in `"secret_access_key"` surfaces only as a runtime mount failure. Golden-JSON test per personality plus a `driverType` table test; both are pure functions. | none |
| L11 | `NetworkFS/GDriveMountConfig.swift:59-63` vs `OneDriveMountConfig.swift:62-68` | Duplication | M | Identical OAuth2 shape, divergent emission: GDrive always sends `client_secret` (empty string included), OneDrive omits it when empty. A driver branching on key presence to pick confidential-vs-public client treats them differently for no stated reason. | none |
| L12 | `NetworkFS/FTPMountConfig.swift:37`, `SFTPMountConfig.swift:40`, `SMBMountConfig.swift:40`, `WebDAVMountConfig.swift:41`, `S3MountConfig.swift:78` | Duplication | M | The same concept — "remote subtree treated as the filesystem root" — is spelled `root`, `root`, `root`, `path`, `prefix`, with no shared key table making the divergence visible or intentional. | none |
| L13 | `NetworkFS/FTPMountConfig.swift:38`, `SFTPMountConfig.swift:41`, `S3MountConfig.swift:74-75` | Duplication | M | `x ? "true" : "false"` hand-written five times across the family. | none |
| L14 | `NetworkFS/DropboxMountConfig.swift:72-90` | Security | M | The same keychain item is interpreted as a long-lived `access_token` or a `refresh_token` purely on whether `appKey` is empty, so an empty-appKey plist silently downgrades the credential's meaning with no log or user signal. | none |
| L15 | `NetworkFS/MountConfigStore.swift:38-124` vs `NetworkFS/MountPolicy.swift:84-151` | Duplication | M | `MountConfigStore` and `MountPolicyStore` are the same 60-line plist store twice over, differing only in subdirectory name and payload type. Extract `AppGroupPlistStore<T: Codable>`. | none |
| L16 | `NetworkFS/MountKeychain.swift:25` | Misleading name | M | `service = "com.antimatterstudios.diskjockey.ftp"` is the keychain service for **all eight** protocols including S3 secret keys and OAuth refresh tokens. | none |
| L17 | `NetworkFS/MountKeychain.swift:40-69` | Security | M | No `kSecAttrAccessible` is set, so items default to `WhenUnlocked` — a FileProvider extension woken while the screen is locked gets `errSecInteractionNotAllowed` instead of the credential, which is exactly the case the shared access group exists to serve. `kSecAttrSynchronizable=false` is applied on the add path only, not the update path. | none |
| L18 | `NetworkFS/NetworkFSPersonality.swift:32-36` | Lying/WHAT comment | M | "Raw values are the ints the C dispatcher expects" sits above an enum whose raw values are `String`s; the ints live in the separate `driverType` property below. | none |
| L19 | `NetworkFS/NetworkFSPersonality.swift:134-137` | Dense expression | M | `encodeMountDict` swallows a serialization failure into `"{}"`, so a malformed config mounts with an *empty* driver config and fails deep inside the driver with no trace of why. | none |
| L20 | `DeviceContexts.swift:138-142` and `:195-201` | Duplication | M | The align-offset / offset-delta / align-length arithmetic is written twice with subtly different block-size rules — exactly where an off-by-one becomes filesystem corruption. Extract one `alignedWindow(offset:length:blockSize:)`. | none |
| L21 | `DeviceContexts.swift:162` vs `:220-222` | Misleading name | M | `read` treats a short device read as `EIO`; `write`'s read-modify-write path silently zero-fills the tail. Two opposite policies for the same condition in adjacent methods, with the write side able to zero out real data. | none |
| L22 | `DeviceContexts.swift:144-153` | Lying/WHAT comment | M | Cache hits deliberately record no stats ("a free read by construction"), so with `readCache` enabled the `bdev_bytes_read`/`bdev_ops_read` counters shipped to the UI systematically under-report actual driver demand. | none |
| L23 | `DeviceContexts.swift:240` | Concurrency hazard | M | Every **successful** block write emits an `info` line, and `NDJSONFileSink.emit` (`AppLog.swift:304`) does a synchronous `queue.sync` file write per line — a disk round-trip per write, while the read path logs nothing. | none |
| L24 | `DeviceContexts.swift:98,270` | Concurrency hazard | M | Neither `BlockDeviceContext` nor `FileDeviceContext` is `Sendable`, yet both are reached from `@convention(c)` driver callbacks via an `Unmanaged` pointer on whatever thread the Rust driver is on. Every other type in this framework carries an explicit `@unchecked Sendable` + justification; these two don't. | none |
| L25 | `DeviceContexts.swift:150` | Concurrency hazard | M | `ptr.baseAddress!` force-unwraps the cached buffer's base address — nil for a zero-length array, which `BlockReadCache` will happily store — turning a cache oddity into an appex crash. | `BlockReadCacheTests` |
| L26 | `BlockReadCache.swift:34-39,60-66` | Magic numbers | M | Header claims "max ~512 entries … ≈2.5 MB", but entries are whole aligned read windows and the motivating case is the 128 KB `$UpCase` table — 512 of those is 64 MB resident in a memory-capped appex. Cap on total bytes. | `BlockReadCacheTests` (12 cases) |
| L27 | `BlockReadCache.swift:54-58,94-100,112-117` | Concurrency hazard | M | `entries` and `accessOrder` are parallel structures whose "same key set" invariant is maintained by hand in four methods, and `insert`'s `accessOrder.removeFirst()` traps if they drift. | `BlockReadCacheTests` |
| L28 | `AppLog.swift:265-313` | Concurrency hazard | M | The NDJSON file in the shared container is opened append-only with no size cap or rotation, and every FSKit extension, the FileProvider and the app each write their own for the life of the install. | none |
| L29 | `AppLog.swift:107-118` | Concurrency hazard | M | `AppLog` is `@unchecked Sendable` and holds `[AppLogSink]` where `AppLogSink: AnyObject` carries no `Sendable` requirement, so any sink supplied via `configure(_:)` crosses isolation domains unchecked. | none |
| L30 | `AppLog.swift:57-70,283,297,298` | Dense expression | M | Every log line constructs a fresh `ISO8601DateFormatter`, and `emit` a fresh `JSONEncoder` and `Logger` — three allocations per line, on a path that also carries `scope: .io` block-device chatter. Hoist to statics. | none |
| L31 | `AppLog.swift:16-18,336-337` | Lying/WHAT comment | M | The header advertises a `StdoutSink` "for CLI-style subprocesses (Go backend, tools) where the host pipes stdio". The class is `StderrSink`, is referenced nowhere, and a MAS-sandboxed app cannot spawn the subprocess described. | none |
| L32 | `IOStats/IOStatsRecorder.swift:12-20` | Lying/WHAT comment | M | Header describes a `preflush` hook that "overlays Go-side transport counters from `networkfs_get_stats()`" as live FileProvider behaviour; no call site installs it. | none |
| L33 | `IOStats/IOStatsRecorder.swift:119-129` | Concurrency hazard | M | `start()` has no idempotency guard (unlike `RepairWatcher.start()`), so a second call orphans the first `DispatchSourceTimer`, which keeps firing forever. | none |
| L34 | `IOStats/IOStatsRecorder.swift:221-224` | Misleading name | M | The `IOStatsCollector` back-compat alias is still the spelling used by the framework's own newest code (`DeviceContexts.swift:108,124,275`), so both names circulate and neither is canonical. | none |
| L35 | `DetachedOperationWatchdog.swift:60-67,147` | Misleading name | M | "Fix D" / "pre-Fix-D" appears in a public doc comment, a `MARK`, and the test suite, with no definition anywhere in the repo — an internal ticket reference standing in for the feature's name. | `DetachedOperationWatchdogTests` (13 cases) |
| L36 | `Errors/DiskTypeError.swift:67`, `Errors/MountError.swift:193`, `Errors/BackendError.swift:252`, `Errors/DiskJockeyError.swift:177` | Duplication | M | Four hand-maintained NSError/URLError mapping tables switching over the identical three `URLError` groups. | none |
| L37 | `Errors/DiskTypeError.swift:67`, `Errors/MountError.swift:193` | Misleading name | M | Both `from(error:)` factories are `internal` inside `public` enums in a framework, so no consumer target can ever call them — the mapping logic they exist for is unreachable. | none |
| L38 | `Errors/BackendError.swift:5-13` | Dead/speculative | M | Eight `process*` cases model spawning and supervising a subprocess backend, which a MAS-sandboxed app cannot do. | none |
| L39 | `Errors/DiskJockeyError.swift:194` | Magic numbers | M | `case NSFileWriteOutOfSpaceError, 640:` — `640` *is* `NSFileWriteOutOfSpaceError`, and the trailing comment says so. | none |
| L40 | `OperationLock.swift:1-83` | Missing coverage | M | The tri-state mutex serialising verify against repair on a live mounted volume has no behavioural test — `MountableFileSystemTests` only constructs it as a fixture field. | none |
| L41 | `DeviceContexts.swift:98-333` | Missing coverage | M | Neither device context has any test, despite owning the block-alignment and read-modify-write arithmetic on which every filesystem's write correctness rests. The arithmetic is pure and testable once extracted per L20. | none |
| L42 | `IOStats/IOStatsRecorder.swift:33-231` | Missing coverage | M | No test at all — not duplicate-snapshot suppression, not the `preflush` write-back, not the forced final flush on `stop()`. Adding them would surface L4. | none |
| L43 | `Network/TCPSocket.swift:16-32` | Dense expression | M | `send` reports failure on a short `write` without retrying (bytes already went out); `receive` returns `nil` on any short `read`, discarding what it received. Both are silent stream corruption. | none |
| L44 | `Network/TCPListener.swift:57-72,79` | Concurrency hazard | M | The accept thread reads `shouldStopAccepting` unsynchronised while `stopAccepting()` writes it from another thread. | none |
| L45 | `Network/TCPConnection.swift:15,24-26` | Dense expression | M | `inet_pton`'s return is ignored, so an unparseable host leaves `sin_addr` zeroed and connects to `0.0.0.0`; a failed `connect` just calls `disconnect()` from a non-failable init, handing the caller a live-looking object with `socket == -1`. | none |
| L46 | `DiskJockeyLibraryTests/` (7 files) | Duplication | M | Five files use XCTest, two use swift-testing, with hand-rolled `LockBox`/`NSMutableArray` spies duplicated across both styles. The project-wide split is 145 swift-testing cases and 48 XCTest — `DiskJockeyTests` is fully migrated, `DiskJockeyLibraryTests` is not. | n/a |
| L47 | `DeviceContexts.swift:108` vs `:275` | Misleading name | L | `BlockDeviceContext.stats` is optional with a long "required-but-optional" justification; `FileDeviceContext.stats` is non-optional for no stated reason, and it also lacks the `readCache`/`writeStrategy` knobs. | none |
| L48 | `DeviceContexts.swift:298` | Dense expression | L | `UInt64(bitPattern: Int64(st.st_size))` turns a negative size into a ~18-exabyte volume instead of failing. | none |
| L49 | `RepairWatcher.swift:73,156` | Dead/speculative | L | `watchedFD` is assigned and never read — the source's cancel handler closes the fd directly — and the class has no `stop()`/`deinit` to cancel the DispatchSource. | `RepairWatcherTests` (6 cases) |
| L50 | `DetachedOperationWatchdog.swift:151,174` | Magic numbers | L | `1_000_000_000` spelled out twice for the seconds→nanoseconds conversion. | `DetachedOperationWatchdogTests` |
| L51 | `DetachedOperationWatchdog.swift:157-158` | Concurrency hazard | L | `armStuckTimer` stores the timer under the lock and calls `resume()` outside it, so a `leave()` landing between the two cancels a not-yet-resumed source. | `DetachedOperationWatchdogTests` |
| L52 | `IOStats/IOStatsRecorder.swift:121-125` | Magic numbers | L | The 1 Hz cadence is two bare `1.0` literals — and 1 Hz is the throttle contract every other emitter must match, so it should be greppable. | none |
| L53 | `Network/TCPListener.swift:50` | Lying/WHAT comment | L | Logs "Listening port was updated to \(port)" but interpolates the *requested* port, not the `portValue` just read back from `getsockname` — the one number the line exists to report. | none |
| L54 | `Network/TCPListener.swift:55` | Magic numbers | L | `Darwin.listen(socket, 5)` — unnamed backlog. | none |
| L55 | `Errors/BackendError.swift:271-274` | Dead/speculative | L | `case (NSCocoaErrorDomain, _)` and `default` return the identical expression. | none |
| L56 | `Errors/BackendError.swift:278-283` | Dead/speculative | L | `userFriendlyMessage` returns `localizedDescription` unchanged, with a comment promising it will do more later. | none |
| L57 | `Errors/BackendError.swift:67-78,89-100,115-126,145-156,179-196`; `MountError.swift:60-109`; `DiskTypeError.swift:15-28` | Duplication | L | The `if let error { "prefix: \(desc)" } else { "prefix." }` shape written nine times in one file and again in two others. | none |
| L58 | `Models/LogModels.swift:49-59` | Misleading name | L | `==`/`hash` consider only `id`, `timestamp`, `message`, so entries differing in `category`, `source`, `scope` or `metadata` compare equal — surprising for a `Codable` value in a `@Published` array. | none |
| L59 | `DiskJockeyLibrary.swift:1-9` | Dead/speculative | L | Empty umbrella file containing only `import Foundation`. | n/a |
| L60 | `DiskJockeyLibraryTests/DiskJockeyLibraryTests.swift:13-15` | Dead/speculative | L | Xcode's placeholder `@Test func example()` with an empty body still ships in the suite. (`DiskJockeyTests/DiskJockeyTests.swift` has the same.) | n/a |
| L61 | `NetworkFS/MountConfigStore.swift:68-72`, `NetworkFS/MountKeychain.swift:52,56,66,70` | Duplication | L | Nine `NSLog` calls in a framework whose whole point includes `AppLog` — they bypass the NDJSON sink, so this diagnostic never reaches the Logs panel. | none |

### 7. DiskJockeyFileProvider

The extension must work with the desktop app not running. It mostly does: it links
libnetworkfs directly, reads config from the app-group plist plus keychain, and logs to
file and os_log. Three findings are genuine liveness dependencies.

| # | Location | Category | Sev | Finding / fix | Tests |
|---|---|---|---|---|---|
| P1 | `MountErrorReporter.swift:145-153` | Backend-independence | H | When an OAuth refresh token dies, the only recovery is the host app's `OAuthRefreshSupervisor` (browser re-auth + domain cycle) — so with the app not running the mount is permanently dead, while the banner unconditionally promises "re-authorising in your browser". Return `NSFileProviderError(.notAuthenticated)` so Finder surfaces a sign-in affordance, and make the message conditional on the app being reachable. | none |
| P2 | `FileProviderExtension.swift:46,64-80` | Backend-independence | H | A transient config/keychain read failure at init leaves `directClient` nil (it's a `let`) for the whole process lifetime, and every op then answers `.noSuchItem`, so Finder prunes a mount that is fine (locked keychain, container not yet mounted). The documented un-prune path is the host app cycling the domain. Make the client lazily re-creatable; map credential failures to `.notAuthenticated`/`.serverUnreachable`. | none |
| P3 | `FileProviderDirectClient.swift:64,106` | Backend-independence | M | Config and password are read once at init and never re-read, so credentials rotated while a mount is live take effect only when the app cycles the domain. Reload inside `ensureConnected` after an auth-class failure. | none |
| P4 | `DiskJockeyFileProvider/` (whole target) | Missing coverage | H | **Zero tests** — confirmed: no test target references any symbol in this directory. Five trivially testable pure functions exist (`humaniseMountError`, the `mountID` FNV hash, `joinPath`, `extractPath`, `ThumbnailCache.bucket`). A logic-only target needs no FP host. | none |
| P5 | `FileProviderExtension.swift:187-280` | God function | M | `fetchContents` is ~93 lines mixing temp-dir selection, the network fetch, metadata synthesis, a double file-size probe, stats bracketing and error mapping, with a 20-line WHY comment mid-body. | none |
| P6 | `FileProviderExtension.swift:246-254` | Dead/speculative | M | The `attrs[.size] as? Int64` branch can never succeed (`attributesOfItem` boxes size as `NSNumber`), so the file is stat'd twice and only the second branch is live. | none |
| P7 | `FileProviderExtension.swift:154-157,191-194,424-427,470-473,521-524` and `:167-179,263-276,457-464,508-515,541-548` | Duplication | M | The same five-part prologue (nil-client guard → global-queue hop → do/catch → `if !(error is FileProviderDirectClientError) { emitMountError }` → `Self.mapError`) is copy-pasted across every entry point, as are the five catch blocks. One `withDirectClient(op:path:completion:)` helper. | none |
| P8 | `FileProviderExtension.swift:598-625` vs `MountErrorReporter.swift:64-194` | Duplication | M | Driver error text is classified twice by two independent substring matchers — a 3-keyword one and a 130-line one — with no shared vocabulary. They will drift by construction. **Highest-value refactor+test target in this directory:** pure functions, zero dependencies, currently 0% covered. | none |
| P9 | `MountErrorReporter.swift:64-194` | God function | M | A 130-line order-dependent if-chain of protocol-blind substring matches, where any driver's "not found" is captured by the WebDAV arm at `:121` and reported as "WebDAV path not found". Match against the mount's known driver first. | none |
| P10 | `FileProviderExtension.swift:570-574` and `FileProviderEnumerator.swift:49-51` | Security | M | `extractPath` silently converts any identifier lacking the `"item-"` prefix into `"/"`, so a malformed identifier reaching `deleteItem`/`removeItem` targets the **remote root**. Duplicated in two files. Return nil and answer `.noSuchItem`. | none |
| P11 | `FileProviderExtension.swift:469-518` and `:423-467` | Misleading name | M | `modifyItem` and `createItem` return an empty `NSFileProviderItemFields`, telling `fileproviderd` "every requested change was applied", while only filename/parent/contents are handled and all other changed fields are dropped. | none |
| P12 | `FileProviderDirectClient.swift:118-139,294-302` | Concurrency hazard | M | `mounted` is guarded by `NSLock` but every C call runs outside it, so `invalidate()` → `networkfs_unmount(mountID)` can race in-flight ops on the same mount; concurrent ops also rest on an undocumented driver thread-safety assumption. | none |
| P13 | `FileProviderDirectClient.swift:321-330` | Security | M | A 31-bit FNV-1a fold is the entire namespace for driver mounts, so a collision silently routes one domain's file ops into another domain's authenticated server session. The comment acknowledges this. Persist a `domainID`→id table in the app group. | none |
| P14 | `FileProviderDirectClient.swift:154-245` | Duplication | M | Six op wrappers (stat/listDir/fetchFile/writeFile/mkdir/removeItem/renameItem) are the same 10-line shape differing only in op name and C call. | none |
| P15 | `MountErrorReporter.swift:34-50` | Security | M | The raw error string is written verbatim as `detail` into the shared app-group NDJSON, and driver `net/url` errors routinely embed the full URL including userinfo for FTP/WebDAV. Redact before emitting. | none |
| P16 | `NetworkFSDriver.swift:220,227,244,247` | Security | M | Every fetch logs the full remote path at info level through the untagged module-global `log` into a sink that never rotates, accumulating an unbounded record of the user's remote filenames in a container readable by every app-group member. | none |
| P17 | `NetworkPathMonitor.swift:34,42-43,53-55` | Concurrency hazard | M | `_isExpensiveOrConstrained` is written on the monitor queue and read from arbitrary queues with no synchronization, inside an `@unchecked Sendable` type. It defaults to `false` for the first moments after every respawn, so the first thumbnail fan-out after a respawn can run on a metered link. | none |
| P18 | `FileProviderEnumerator.swift:212-219` | Concurrency hazard | M | `currentSyncAnchor` mints a brand-new anchor on every call so `fileproviderd` re-enumerates continually, and each enumeration fans out a fresh detached prewarm group (`:132-193`) — a self-retriggering network amplifier the 5-minute cache only partly absorbs. | none |
| P19 | `FileProviderEnumerator.swift:149-190` | Concurrency hazard | M | Prewarm tasks run in the Swift cooperative pool but every `ThumbnailCache.get/put` blocks that thread on `queue.sync` against SQLite (`ThumbnailCache.swift:69-80`), so four concurrent prewarms can starve the pool. | none |
| P20 | `ThumbnailCache.swift:147-159` | Concurrency hazard | M | Every `put` runs a DELETE-by-`fetched_at` vacuum inside the one serial queue all `get`s block on, so a 200-photo prewarm performs 200 table scans that stall every concurrent lookup; the statement's result is unchecked. | none |
| P21 | `FileProviderExtension.swift:89` vs `FileProviderDirectClient.swift:57` | Misleading name | M | `mountID` is the domain `String` in one place and the FNV `Int32` in the other, converted inline at the init site with a local named `goMountID` to paper over it. | none |
| P22 | `NetworkFSDriver.swift:218-252`, `FileProviderExtension.swift:448,495` | Concurrency hazard | M | `fetchContents` materialises the entire remote file in a driver buffer, copies it into a Swift `Data`, then writes it to disk — three copies; uploads do `Data(contentsOf:)` on the whole file. A multi-GB file will OOM the extension. | none |
| P23 | `FileProviderEnumerator.swift:13` | Dead/speculative | L | The `anchor` property built from the literal `"an anchor"` is never read. | none |
| P24 | `FileProviderEnumerator.swift:151,178-180` | Dead/speculative | L | `inFlight` is incremented and then never decremented or read. | none |
| P25 | `FileProviderEnumerator.swift:155-156` | Dense expression | L | The child path is computed twice, re-implementing `joinPath` while `RemoteFileInfo.path` already carries the server's own path. | none |
| P26 | `FileProviderEnumerator.swift:200-210` | Magic numbers | L | An 18-entry hard-coded extension allowlist duplicates the `UTType` derivation `FileProviderItem.contentType` already performs. | none |
| P27 | `ThumbnailCache.swift:186-190` | Magic numbers | L | The bucket ladder is a bare literal array that must stay in lockstep with `FileProviderEnumerator.prewarmSizePx` (256) and the driver's provider enum, with nothing linking them. | none |
| P28 | `ThumbnailCache.swift:51-63` | Dead/speculative | L | If the app-group container is unavailable the cache silently degrades to a per-process temp dir — defeating the "survives respawn" rationale in its own file header — with no log line. | none |
| P29 | `ThumbnailCache.swift:39-63` | Concurrency hazard | L | The sqlite handle is opened once and never closed (no `deinit`/`sqlite3_close`), so journal state can outlive an abrupt teardown. | none |
| P30 | `NetworkPathMonitor.swift:30-33` | Lying/WHAT comment | L | The comment says the value is "Protected by `queue`" and in the next clause says reads happen on the caller's queue — it documents the absence of protection as though it were protection. | none |
| P31 | `FileProviderExtension.swift:359-366` | Too many params | L | `fetchThumbnailsInBackground` takes six arguments, four of them FP callbacks forwarded verbatim. | none |
| P32 | `FileProviderItem.swift:102-120` | Magic numbers | L | `schemaVersion = 3` is a hand-maintained cache-buster buried in a function body behind a 12-line comment about a past bug; also a doubled force-unwrapped `data(using:.utf8)!` at `:116-119`. | none |
| P33 | `FileProviderExtension.swift:128-135` | Misleading name | L | The root container is built by passing `DiskJockeyFileItem(name: "")` and relying on empty-name special cases in three separate computed properties. Add an explicit `FileProviderItem.root()`. | none |
| P34 | `NetworkFSDriver.swift:259-285` | Deep nesting | L | `writeFile` nests `withCString` → `withUnsafeBytes` → `bindMemory` → `ByteSlice` four levels, with the zero-length case duplicated inside. | none |
| P35 | `NetworkFSDriver.swift:247` | Dense expression | L | A log line combining `try?` + subscript + `as?` + `?? -1` to print a file size. | none |
| P36 | `MountErrorReporter.swift:115-126` | Dense expression | L | HTTP status matching depends on the literal `" 401 "` with surrounding spaces, so `"401:"` or `"(401)"` falls through to a generic message. | none |
| P37 | `MountErrorReporter.swift:34,55,64`, `FileProviderItem.swift:125` | Misleading name | L | `emitMountError`/`emitMountErrorCleared`/`humaniseMountError`/`joinPath` are unnamespaced global functions in a target that links `DiskJockeyLibrary`. | none |
| P38 | `DiskJockeyFileProvider/Info.plist:11-12` | Dead/speculative | L | `NSExtensionFileProviderSupportsEnumeration` is a legacy non-replicated-API key carried on an `NSFileProviderReplicatedExtension`. | n/a |

**No sandbox violation found in the File Provider extension** — no `Process()`, `NSTask`,
`NSXPCConnection` or `NSWorkspace` anywhere in the directory.

### 8. DiskJockeyAgent

Security findings X1-X7 above are the substance here. Remaining:

| # | Location | Category | Sev | Finding / fix | Tests |
|---|---|---|---|---|---|
| G1 | `AgentImpl.swift:49-54,73-77,173-185` | Concurrency hazard | H | Every `Process` call does `waitUntilExit()` **before** draining stdout/stderr, so any child exceeding the ~64 KB pipe buffer (`hdiutil info -plist` with several images attached, `diskprobe`'s JSON) deadlocks the agent and wedges that XPC connection permanently. Same bug as A4, in the privileged process. | none |
| G2 | `AgentImpl.swift:189-213` | Security | M | The binary to execute is located by walking up three path components from `CommandLine.arguments[0]` — the exec target derived from argv rather than the real image path. Use `Bundle.main.url(forAuxiliaryExecutable:)` and verify what you exec. | none |
| G3 | `AgentImpl.swift:112-129,165-187` | Concurrency hazard | M | No `Process` has a timeout and `waitUntilExit()` runs on the XPC connection's thread, so a hung `hdiutil` blocks that connection and the app call behind it indefinitely. | none |
| G4 | `AgentImpl.swift:10-38` | Dense expression | M | The retry is a switch whose failure arm falls out of the statement into a second switch, with the recovery condition buried in a guard containing an inline regex — 29 lines to say "attach; on failure detach the stale device and retry once". | none |
| G5 | `AgentImpl.swift:100-108,110-129` | Duplication | M | `hdiutilDetach` and `detachDevice` are the same six lines differing only by `-force` and whether exit status is reported. | none |
| G6 | `AgentImpl.swift:7` | Dead/speculative | L | `extension String: @retroactive Error` conforms a stdlib type module-wide purely so one internal `Result` can use a string failure. | none |
| G7 | `AgentImpl.swift:200-211` | Dead/speculative | L | The `DEBUG` `#filePath` walk-up bakes the build machine's source layout into dev builds and silently changes which binary executes between Debug and Release. | none |
| G8 | `DJAgentProtocol.swift:8-10` | Too many params | L | `mountFSKit` takes five positional parameters (two a coupled offset/length pair) plus the reply. | none |

---

## Test coverage

No test run was performed — this pass made no changes, so there is no before/after to
compare, and building would have written a fresh DerivedData tree. The numbers below are
static counts.

| Target | Cases | Framework |
|---|---:|---|
| `DiskJockeyTests` | 131 | swift-testing (fully migrated) |
| `DiskJockeyLibraryTests` | 14 swift-testing + 45 XCTest | mixed |
| `DiskJockeyUITests` | 3 XCTest | XCTest |
| **Total** | **145 swift-testing + 48 XCTest** | |

Where the coverage is and isn't:

| Area | Covered by | Gap |
|---|---|---|
| `FileSystemItem`, `FileIDCache`, `BlockReadCache`, `MountedResourceRegistry`, `RepairWatcher`, `DetachedOperationWatchdog` | 6 files, ~58 cases | Only EXT4/NTFS tags tested — not Squashfs/Erofs, and there is no Xfs/Btrfs tag to test (F1) |
| EXT4, NTFS, EROFS, SquashFS volumes | `EXT4VolumeTests`, `NTFSVolumeTests`, `ErofsVolumeTests`, `SquashfsVolumeTests` | **XFS and BTRFS have none** (F18) — the two files the copy-paste damaged |
| `SwiftPartitionProbe`, `MountTableParser`, `DiskEventHandler`, `AttachedDisksModel` | 4 files, 61 cases | The two duplicate probe implementations (V20, V21) are uncovered |
| `DiskJockeyLibrary/NetworkFS/` (8 configs, the driver ABI) | — | **none** (L10) |
| `DeviceContexts` block alignment / RMW arithmetic | — | **none** (L41) |
| `IOStatsRecorder` | — | **none** (L42) |
| `OperationLock` | — | **none** (L40) |
| `DiskJockeyFileProvider` | — | **none** (P4) |
| `DiskJockeyAgent` (incl. the shell quoting) | — | **none** (X7) — and the target isn't in the project file at all (X3) |

Coverage tracks the 2026-06-02 refactor, not risk. Everything tested is a dependency-free
data structure; everything untested is where the money is — block-alignment arithmetic, the
driver ABI key names, the App-Group path layout, the verify/repair mutex, and the quoting
in front of a root shell. The `mountJSON` golden tests and the alignment-window tests are
both cheap (pure functions, no FSKit host needed) and each would catch a class of silent
runtime failure.

---

## Cross-cutting notes

1. **The sandbox story is inconsistent, not absent.** The app declares
   `com.apple.security.app-sandbox` and then spawns subprocesses from eight places, while
   an unsandboxed helper built exactly for that work sits unused for most of them. The
   infrastructure to fix it already exists in-tree. Separately, the entitlement the helper
   depends on is a `temporary-exception`, which is the kind App Store review rejects — that
   deserves a decision before more code is built on it.

2. **Comments have outlived their code in a consistent pattern.** Almost every
   Lying/WHAT finding sits where a mechanism was replaced and the prose stayed: `mount -F`
   → Disk Arbitration, `pluginkit` → `FSClient`, `hdiutil` → the XPC agent, the Go backend
   → nothing, `vendor/` → sibling checkouts. Comment quality here is otherwise unusually
   high — most explain *why*, and several record real hard-won platform behaviour. The
   failures cluster at exactly three or four renames.

3. **The FSKit family's duplication has already started paying out.** The six extensions
   are near-identical by design, and the divergences are not in the interesting places —
   they are a stale superblock comment (F4, F5), a `sed`-mangled errno name (F2), a shared
   phantom tag that voids a documented type guarantee (F1), inherited capability flags that
   are wrong for two filesystems (F6), one member with 3 media types where five have 52
   (F7), and one member that never got the magic-number cleanup (F11). Every one of those
   is a copy-paste artefact, and every one is invisible to the compiler and to the tests.

4. **The App Group container is the real IPC surface and it is under-specified.** Five
   copies of the group identifier, three separate directory layouts, an unvalidated
   `domainID` used as a path component, an unbounded log file, and a spec comment that
   disagrees with its own code. One `AppGroupPaths` type owning the identifier, the
   subdirectory names and identifier validation would close a security finding and three
   duplication findings at once.

5. **`@unchecked Sendable` is applied thoughtfully in six places and forgotten in two.**
   `FileIDCache`, `MountedResourceRegistry`, `BlockReadCache`, `OperationLock`,
   `RepairWatcher` and `DetachedOperationWatchdog` each carry a written justification.
   `IOStatsRecorder` claims the same posture while holding two genuinely unguarded `var`s,
   and `AppLog` claims it while storing a non-`Sendable` sink array. Those are the two
   places where the annotation is a claim rather than a contract.

6. **`Task { … }` without ownership is the recurring concurrency shape.**
   `AppContainer.swift:111`, `ExtensionStateService.swift:81`,
   `OAuthRefreshSupervisor.swift:89`, `DiskArbitrationService.swift:64,70,235`,
   `LogTailService.swift:101`, `AttachedDiskDetailView.swift:660`. None are stored, none are
   cancellable, and two hop when they are already on the right actor.

7. **Credential handling is 80% right, which is the dangerous fraction.** The
   keychain/plist split is correct and well documented for passwords and refresh tokens —
   and then three configs put a live access token or STS session token in the plist anyway,
   the registry persists the whole config (secrets included) into app-group `UserDefaults`,
   and the keychain items lack `kSecAttrAccessible`, which will bite specifically in the
   FileProvider-woken-while-locked case the shared access group exists to serve. A
   one-paragraph "what may be stored where" rule plus a `redactedForPersistence` projection
   would close all of it.

8. **Roughly 1,300 lines are unreachable**, and one of them is worse than unreachable:
   `AppContainer.appLogger` force-casts to a protocol nothing conforms to. Deleting
   `DiskJockeyLibrary/Network/`, `DiskJockeyLibrary/Errors/`, `AppError.swift`,
   `MenuBarController.swift` and the `AppLogger` protocol removes eight findings outright
   and shrinks a framework that six sandboxed targets load.

---

## Method

Files were read directly; no build was run and no test was executed. Duplication claims
were established by `diff` between the actual files and are quoted with their differing-line
counts. Every High-severity security and sandbox claim in sections 1-3 was verified
independently against the source, the entitlements, the `Info.plist` files, the asset
catalog, and `project.pbxproj` before being written down — including the two that turned out
to need correcting: the agent's code-signing requirement **is** present (the gap is on the
client side, X1, plus the missing anchor clause, X2), and `DJAgentProtocol.swift` has **not**
drifted between its two copies (the risk is structural, X11).

Suggested next step: re-run this as a Phase 2 dev-loop over the "Fix first" list only,
one item per change, with the missing XFS/BTRFS volume tests added before item 4 is touched.
