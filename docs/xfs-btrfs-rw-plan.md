# Read-write support for XFS and Btrfs — plan and IP protocol

**Date:** 2026-08-25
**Status:** plan. Nothing below is implemented yet except where marked.
**Internal document.** It names GPL-licensed tools directly, which the public vendor
repositories must not do. Do not copy it into `rust-fs-xfs` or `rust-fs-btrfs`.

---

## 1. The licensing fact that shapes the engineering

For **reading** these formats there were permissively-licensed references to work
from: Haiku's drivers are MIT, and both formats have published on-disk documentation.
That is how both crates were built.

For **writing** there are none. Every complete write implementation of either
filesystem is GPL:

| Implementation | Licence | Usable as a source? |
|---|---|---|
| Linux kernel `fs/xfs`, `fs/btrfs` | GPL-2.0 | **No** |
| `xfsprogs` (mkfs.xfs, xfs_repair, xfs_db) | GPL-2.0 | **No** as source; **yes** as a black-box oracle |
| `btrfs-progs` (mkfs.btrfs, btrfs check) | GPL-2.0 | **No** as source; **yes** as a black-box oracle |
| Haiku | MIT | Read-only; no write path to learn from |

So the write paths cannot be derived from any existing implementation. They have to be
built from format documentation and validated behaviourally.

### What this actually forbids, and what it does not

**Forbidden:**
- Reading kernel or `-progs` source to learn how an algorithm works, then writing our
  own version of it. Clean-room means the person writing the code has not read the
  implementation, not merely that they retyped it.
- Translating or transliterating any of it.
- Copying constant tables, magic values or struct layouts *out of source files*.

**Allowed:**
- Published on-disk format documentation, and constants taken from it.
- Running the GPL tools as black boxes: `xfs_repair -n` on an image we wrote,
  `btrfs check` on an image we wrote, mounting under Linux and comparing. Executing a
  program does not create a derivative work of it. We already do this throughout the
  read path.
- Observing the bytes those tools produce and matching them. A filesystem image is
  data, not code.

### The liberating consequence

**We do not have to reproduce their algorithms. We have to satisfy their validators.**

Our block allocator need not choose the same blocks the kernel would. It needs to
produce a filesystem that `xfs_repair` and `btrfs check` call valid, and that the
kernel mounts and reads back correctly. That is a much weaker obligation than
behavioural equivalence, and it is checkable — which the read path has already proved
works, since ten real defects were caught that way and none by inspection.

It does mean **the oracle carries more weight than usual**. On the read path a wrong
guess produced wrong bytes we could compare against a known answer. On the write path a
wrong guess produces an image that looks fine to us and that the checker rejects — or,
worse, that the checker accepts and the kernel later corrupts. Every phase below is
defined by what the oracle must say, not by what code exists.

---

## 2. The two filesystems are not symmetric

This is the single most important planning fact, and it is easy to miss.

### XFS journals metadata, not data

An overwrite of existing file data, inside an extent that is already allocated and
already written, changes **no metadata at all**. No allocation, no extent-tree change,
no timestamp that must be atomic with anything. Nothing that needs the log.

That makes a genuinely safe first increment available: in-place data overwrite. It is
useful on its own, it exercises the whole device-write path end to end, and it cannot
corrupt a filesystem even if it crashes mid-write — the failure mode is a partially
written file, which is the same failure mode the kernel has.

### Btrfs is copy-on-write, so nothing is in place

There is no equivalent first step. A single-byte overwrite in Btrfs requires, at
minimum:

1. allocate a new block (extent tree, free-space accounting)
2. write the data
3. compute and store its checksum in the checksum tree
4. update the file extent item to point at the new block
5. rewrite every B-tree node from that leaf up to the root, because none may be
   modified in place
6. update extent-tree back references for both the new block and the old one
7. write a new superblock naming the new tree roots and a new generation

Steps 1, 6 and 7 are the hard ones, and step 6 is the part `btrfs check` is least
forgiving about.

**Consequence:** XFS reaches useful read-write far sooner. Btrfs's first increment is
most of a transaction engine. Sequencing them in parallel would leave Btrfs looking
stalled for a long time; sequencing XFS first delivers something usable while the Btrfs
foundations are built.

---

## 3. Phases

Each phase names the oracle that closes it. A phase is not done when the code exists;
it is done when the checker agrees.

### XFS

| Phase | Work | Oracle |
|---|---|---|
| **X1** | In-place data overwrite within allocated, written extents. Writable device plumbing, `is_writable` gating, refusal on unwritten/sparse/shared extents. | `xfs_repair -n` clean after; kernel mount reads back the written bytes; SHA-256 matches |
| **X2** | Timestamp and mode updates — the first metadata writes, and so the first that need the log. Log record construction, one transaction shape. | `xfs_repair -n` clean; kernel sees the new mtime after a mount that replays |
| **X3** | Allocation: free-space B+trees (`bnobt`/`cntbt`) insert and delete, kept mutually consistent. Extend a file, allocate new extents. | `xfs_repair -n` clean; free-space accounting matches after many alloc/free cycles |
| **X4** | Inode allocation (`inobt`, `finobt`), create and unlink. | `xfs_repair -n` clean; kernel `ls` matches |
| **X5** | Directory modification across short-form, block, leaf and node, including the format transitions between them. | `xfs_repair -n` clean; kernel reads every entry |
| **X6** | `bmbt` insertion — the write half of the walker landed in 0.4.0. | `xfs_repair -n` clean on heavily fragmented files |

**X2 is the real gate.** Everything from X3 on depends on being able to journal a
transaction correctly. It is worth building the log writer carefully and slowly, with
the smallest possible transaction, before anything else needs it.

### Btrfs

| Phase | Work | Oracle |
|---|---|---|
| **B1** | Transaction skeleton: CoW a B-tree path, write new tree roots, commit a new superblock generation. No user-visible change — modify nothing, but commit a generation the kernel accepts. | `btrfs check` clean; kernel mounts at the new generation |
| **B2** | Extent tree: allocate and free blocks with correct back references. | `btrfs check` clean, specifically no extent-tree errors, after many cycles |
| **B3** | Data write: new extent, checksum item, file extent item update. Overwrite an existing file. | `btrfs check` clean; kernel reads back the written bytes |
| **B4** | B-tree insert and delete with node split and merge. | `btrfs check` clean across trees forced to split |
| **B5** | Create, unlink, rename; directory index items. | `btrfs check` clean; kernel `ls` matches |

**B1 and B2 are the whole risk.** If the transaction and extent accounting are right,
the rest is comparatively mechanical. If they are wrong, everything built on them has
to be redone.

---

## 4. Safety posture

Both drivers currently refuse to mount when the filesystem is mid-operation — XFS on a
dirty log (as of 0.4.0, correctly), Btrfs on a non-empty log tree. **That refusal
becomes more important, not less, once writing is possible**, and must stay: writing to
a filesystem whose log holds unapplied work would compound stale metadata with new.

Additionally:

- **Read-write is opt-in per mount**, and the default stays read-only. A driver that
  can write should not write because the device happened to be writable.
- **Every phase ships behind its own refusal.** X1 refuses unwritten, sparse and
  reflinked extents rather than guessing; each later phase narrows what is refused.
  Refusing is always the correct answer for a case not yet implemented, and it is
  never acceptable to write something approximate.
- **No partial transactions.** Where a phase cannot complete an operation atomically,
  it must not begin it.

---

## 5. Provenance protocol for this work

To keep the clean-room claim defensible, for the duration of the read-write work:

1. **Format documentation only.** Where a constant or layout is used, the source
   document is cited in the code, as the read path already does — see
   `rust-fs-btrfs/src/btree.rs`, which states which structures its offsets came from
   and how each was independently corroborated.
2. **Corroborate arithmetic.** Where a value cannot be cited, it must be derivable
   twice — the existing convention of "the struct size is the sum of its own fields,
   and the leaf area is `nodesize - HEADER_SIZE`" is the pattern.
3. **Oracles are executed, never read.** The tools are run and their verdicts recorded.
   Nobody working on this reads their source.
4. **Anything uncorroborated is called out at its use site**, so a later reader knows
   which values are load-bearing guesses.
5. **The vendor repositories never name the GPL tools** in source, README, CLI output
   or commit messages — the existing policy. This document is where they are named.

## 6. Recommended order

**X1 first.** It is safe, self-contained, needs no journal, and it builds the writable
device plumbing every later phase uses. It is also the only phase in either filesystem
that can be delivered without a transaction engine, so it is the cheapest way to prove
the whole write path end to end.

**Then X2**, slowly, because everything downstream rests on it.

**Btrfs B1 can start in parallel** once X1 is done, since it shares no code with XFS and
its risk is concentrated at the front. But it should not be started before X1, because
X1 will teach us things about the writable-device plumbing and the test harness that
B1 would otherwise have to discover independently.

---

## 7. Findings from the first attempt at the log writer — 2026-08-25

X1 (in-place data overwrite) and X2a (inode attribute updates) both landed and are
validated against the kernel. The log writer was started and **deliberately stopped**;
this section records what was established so a later attempt does not re-derive it.

### The record layout, confirmed against real bytes

Read off a filesystem the kernel wrote, not from documentation, so these are facts
rather than recollections:

| Field | Observed |
|---|---|
| `h_version` | 2 |
| `h_fmt` | 1 (`XLOG_FMT_LINUX_LE`) |
| `h_size` | 32768 — the iclog size |
| Record geometry | 1 header block + 63 data blocks = 32 KiB, `h_len` = 32256 |
| `h_prev_block` | the previous record's start block; −1 for the first |
| `h_lsn` | `(cycle << 32) | block`, so ordering by the whole `u64` orders by cycle |

**The cycle stamp is confirmed.** Each data basic block's first four bytes are replaced
by the cycle number, and the displaced word is stored in `h_cycle_data[k]` for block
`k`. The unmount record makes this unmistakable: its data block reads `0x00000001`
(the cycle) where the op header's `oh_tid` should be, and `h_cycle_data[0]` holds
`0xb0c0d0d0`, which is the real tid.

**The unmount record's shape**, which is the simplest record and therefore the right
first thing to write:

```
op header:  oh_tid = <nonzero>  oh_len = 8  oh_clientid = 0xaa  oh_flags = 0x20
payload:    magic 0x556e ("Un"), then padding to 8 bytes
h_num_logops = 1,  h_len = 512
```

### The blocker: `h_crc` could not be reproduced

Ten candidate spans were computed against five real records and **none matched**:
header block plus data at `h_len`, plus data rounded to whole basic blocks, header
truncated to `sizeof(xlog_rec_header)`, header alone, data alone, and each of those
again with the cycle stamp undone and with `h_cycle_data` zeroed.

CRC32C itself is not in question — the same routine verifies superblocks, inodes and
directory blocks in this crate. What is unknown is **what bytes the log's checksum
covers, and at what point in the write they are taken.**

Until that is settled, a log writer cannot be trusted, and an untrusted one is worse
than none: a record the kernel accepts but misreads would be replayed over good
metadata.

### One lead worth following first

**The initial unmount record `mkfs` writes has `h_crc = 0`**, on a v5 filesystem whose
other records carry real checksums, and the kernel mounts that volume without
complaint. That strongly suggests zero is understood as "not computed" and tolerated.

If that holds for a record at the head — not merely one buried behind newer ones — then
a first log writer could emit zero-CRC records and sidestep the unknown entirely. That
is a cheap experiment and it is the one to run next: write an unmount record with
`h_crc = 0` onto a clean fixture and see whether the checker and the kernel still accept
the log.

It is a lead, not a conclusion. It has not been tested.

### Revised estimate

The log writer is a larger piece of work than either phase delivered so far, and its
failure mode is worse. It needs, beyond the checksum question: transaction reservation,
tail-LSN management, iclog alignment, the item formats for each structure logged, and
the logged inode layout, which differs from the on-disk one.

**It deserves its own project rather than a phase.** Everything after it in §3 — X3
onward, and all of Btrfs — depends on it, so the sequencing in this document still
stands; the estimate for reaching it does not.

### What remains available without it

Worth checking before assuming the write path is blocked:

- **Truncate to a smaller size.** Setting `di_size` down while leaving the blocks
  allocated breaks no invariant — post-EOF blocks are legal and XFS keeps them
  routinely — so it may fall inside the same envelope as X2a. Cheap to test with the
  existing oracle, and it would make truncate work.
- **Growing into an already-written extent past `di_size`.** Rare, since preallocation
  produces *unwritten* extents, which are refused for good reason.

---

## 8. What the checksum experiments settled — 2026-08-25, later

The `h_crc = 0` lead from §7 is **dead**, and the three behaviours below are now known
rather than guessed. Each was observed by altering a real record and watching what the
kernel did.

| Record's `h_crc` | What the kernel does |
|---|---|
| Correct | Replays it normally |
| Wrong, non-zero | *"Torn write (CRC failure) detected at log block 0x42. Truncating head block from 0x7a."* — the record and everything after it is discarded, and the mount succeeds |
| Zero | **Mount fails**, `log mount/recovery failed: error -117` (EFSCORRUPTED) |

Two consequences, and the first is better news than it looks.

**Getting the checksum wrong is fail-safe.** A record with a bad checksum is treated as
a torn write and thrown away — the transaction does not happen, and nothing is
corrupted. That is a far gentler failure than the one assumed in §7, where the worry
was a record the kernel accepts but misreads. It substantially de-risks building a log
writer: the worst outcome of a bug is a write that silently did not take effect, which
a test catches immediately.

**Zero is the one value to avoid.** It is not "not computed" — it fails the mount
outright, which is worse than a wrong value. Any writer must compute something, and
must never leave the field clear.

Note also that a *clean* log is not gated on the checksum at all: both a zeroed and a
corrupted `h_crc` on the head unmount record still mounted. Only replay verifies it.
So the checksum matters exactly when a record has to take effect.

### The span is still unknown, and the search was exhaustive

Two systematic sweeps against three real records, both negative:

- **Every contiguous span** beginning at the record start or the data start, in 4-byte
  steps up to the whole 32 KiB record, against four finalisations of the stored value
  (as-is, inverted, byte-swapped, both) — and with the cycle stamp both applied and
  undone.
- **Every subset of eight header fields** being zero at checksum time (`h_cycle`,
  `h_len`, `h_lsn`, `h_tail_lsn`, `h_prev_block`, `h_num_logops`, `h_cycle_data`,
  `h_size`), again stamped and unstamped — 512 combinations.

CRC32C itself is not in question: the same routine verifies superblocks, inodes,
directory blocks and B+tree blocks in this crate.

**So the buffer checksummed is not the record as it sits on disk.** The likely
explanation is that it covers the in-memory iclog before it is written — which may
include bytes that never reach the disk, or reach it rearranged. Cracking it needs a
different technique than sweeping: most promising is to make the filesystem produce a
record whose content is small and fully known, and work from that.

This is a research problem, not a task with an estimate, and it should be picked up as
one.

---

## 9. The checksum is solved — 2026-08-26

§7 and §8 describe this as a research problem with no estimate. It is
neither any more.

```
h_crc = crc32c( header[0..328] with h_crc zeroed  ++  data[0..h_len] )
```

Two things were wrong in every earlier attempt:

- **The header contributes 328 bytes**, `sizeof(xlog_rec_header)` with its
  fields padded to the 8-byte alignment its `u64` members impose — not the
  512-byte basic block it occupies on disk. The other 184 bytes are padding the
  checksum never sees, and every contiguous-span sweep in §8 included them.
- **The data is the stamped form**, cycle numbers already in place. The checksum
  is taken after packing. Unstamped matches nothing.

Verified against 37 checksummed records across 6 filesystems the kernel wrote;
`rust-fs-xfs/tests/log_checksum_oracle.rs` holds it.

### The method, which is the part worth keeping

Guessing harder was not going to work — ten layouts had already been tried and
all ten were wrong. What worked was a property of the algorithm rather than a
better guess.

**CRC32C is affine.** For two inputs of the same length, `crc(A) ^ crc(B)`
depends only on where they differ; any unknown seed, final xor or constant
prefix cancels. So a candidate span can be tested by whether it reproduces a
*difference*, without being able to reproduce either absolute value.

That turns an unbounded search into a bounded one, and it needs a pair of
near-identical inputs:

1. Build two filesystems identically — same `mkfs` arguments, and `-m uuid=` to
   force the same UUID, or every byte differs.
2. Make one minimal, different change in each. One byte of file data was enough;
   261 bytes of the whole image differed.
3. Find a record whose only real difference is a few bytes at a known offset.
   One differed only in `h_cycle_data[0]`.
4. Sweep span lengths for the one that reproduces the checksum difference.
   Exactly one did: **840**.
5. 840 = 328 + `h_len`, and 328 is the header struct rather than its block.

The same technique applies to any checksum in either format whose coverage is
unclear, and to the item formats still to be worked out — build two filesystems
differing by one controlled thing and read the difference.

### What this unblocks

The log writer, and everything in §3 that depends on it: XFS allocation,
inode allocation, directory modification and `bmbt` insertion — which is to say
create, unlink, rename, and growing a file.

The remaining unknowns are the item formats: `xfs_inode_log_format`, the logged
inode layout, and the transaction framing around them. Those are structure
rather than arithmetic, and the differential method above is the way to
establish them.

**One thing that has not changed**: a record whose checksum does not verify is
discarded as a torn write, so a wrong implementation still fails safe. That
remains the reason this is worth attempting incrementally.

## 10. The log writer works — 2026-08-26

The kernel replays a record `rust-fs-xfs` wrote. That is the phase-boundary this
document has been working towards since §3: every metadata change beyond a
single-inode in-place edit needs a log record, and now one can be produced.

`Filesystem::log_inode_core` logs a new core for an inode **without touching the
inode**. Mounting the volume makes the kernel's own recovery apply it. The proof is
`tests/log_replay_oracle.rs`: root's mode logged 0755 → 0751, the inode on disk left
alone, our own driver then refusing the volume as dirty, the kernel mounting it and
reading 0751, and the reference checker finding nothing wrong.

Leaving the inode alone is the whole design of that test. A driver that wrote both
would pass a mode check while proving nothing about the log.

### The field that was missing, and how it fails

A logged inode does not name its own address. It names the inode **cluster** holding
it — `ilf_blkno`, `ilf_len`, `ilf_boffset` — and the replayer reads that whole cluster
to apply the change. Those three were zero, and the failure is worth recognising
because it does not point at itself:

```
XFS (loop2): Starting recovery (logdev: internal)
XFS (loop2): metadata I/O error in "xlog_recover_items_pass2" at daddr 0x0 len 0 error 5
XFS (loop2): log mount/recovery failed: error -5
```

The record checksums. The kernel finds it, trusts it, and *starts* recovery. Then it
reads block 0 for 0 bytes and refuses the mount, naming neither the inode nor the
record. Every visible signal says the record was fine.

The cluster size is not in the record — it comes from the geometry: 8 KiB scaled by
how many 256-byte minimum inodes fit in one of this filesystem's, truncated to whole
blocks. Confirmed against 7,307 inode items the kernel wrote across four allocation
groups and four geometries.

### Why this stayed safe to develop

A record whose checksum does not verify is discarded as a torn write: the kernel
truncates the head back and the transaction simply never happened. A record with a
**zero** checksum fails the mount instead. So a wrong encoding costs an experiment,
not a filesystem — which is what made it reasonable to iterate against a real kernel
rather than trying to get it right on paper first.

### What comes next

**Rename within one directory**, for the reasons §6 already gave: 8 ops, 2 items, both
inode items, no buffer item, no allocator metadata. It is a strict extension of the
shape that now works — the same START, transaction header, inode format, inode core
and COMMIT skeleton, plus one more inode item and one fork-data op.

The op sequences for twelve operations are in the crate's `docs/transaction-shapes.md`.

### An unrelated bug the same week's work surfaced

Worth recording because of *how* it was found rather than what it was. Fixtures built
by a stress generator — rather than by someone deciding what to put in them — caught
`read_link` returning the block holding a symlink target instead of the target, within
a minute of the first one existing.

It had been wrong for as long as the function existed, and no hand-written fixture had
ever contained a target long enough to leave the inode. The lesson generalises: the
fixtures we choose test the cases we thought of.
