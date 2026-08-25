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
