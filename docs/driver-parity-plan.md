# Closing the gap to the kernel drivers

A backlog, ordered by what it buys against what it costs. Written
2026-09-06 from each driver's own status tables and read paths, not from
a wishlist: every item below is something a driver currently refuses,
does not implement, or does slowly for a reason visible in the code.

## The order, and the one rule that overrides it

Tiers run best-gain-first, **except that a data-corruption defect
preempts everything**. A driver that is slow costs someone time; a
driver that writes a wrong byte costs someone their filesystem, and
they may not find out for weeks. Anything in Tier 0 stops the tier
below it until it is fixed.

---

## Tier 0 — corruption

**Nothing open as of 2026-09-06.** The two places most likely to hold
one were checked when this list was written:

- **XFS, a second journalled write in one mount.** It is refused, by an
  atomic swap in `begin_checkpoint`, with a message naming why: a
  second record would be built from a disk that does not yet reflect
  the first.
- **btrfs, overwriting in place.** Refused for a copy-on-write inode,
  for a `nodatacow` inode that is still checksummed, for an offset that
  is inline or preallocated, and for any extent whose reference count is
  not one — which is the snapshot case.

Both are guards rather than absences, which is the shape to want.

**0.1 — a corruption-focused audit pass.** "Two places were checked" is
not "there are none". One pass per driver over the write paths, asking
one question: is there an edit that can be applied to a filesystem the
driver has misread? The write-path audit that produced tasks 84 and 85
is the template.

---

## Tier 1 — performance, and it is all one shape

The largest gain available, because it is the only work here that
improves **every** driver at once and cannot write a wrong byte: none of
it touches the on-disk format.

`am-fs-core` ships `CachingDevice`, an LRU block cache. **Four of the
six drivers never use it** — ntfs, xfs, btrfs and squashfs read every
metadata block from the device, every time. Nothing in the Swift layer
wraps the device either. So a directory listing walks the inode B+tree,
then the block map, then each directory block, and the next listing
re-reads all of it.

Underneath, `FileDevice::read_at` is `seek` + `read` under a single
mutex, so every one of those reads is a syscall and concurrent readers
serialise even where the device would not.

**1.1 Measure first.** A repeatable read-path benchmark per driver —
mount, walk a tree of known shape, read a known set of files — reporting
device reads and wall time. Without this the rest is decoration.
*Done when*: a number exists for each driver, recorded and reproducible.

**1.2 Wire the cache.** One decision to make and record: wrap at each
driver's mount, or once at the FSKit boundary where the device is
created. One place is better if the drivers' access patterns are alike;
per driver is better if their block sizes differ enough to want
different cache geometry.
*Done when*: 1.1's numbers move, and by how much is written down.

**1.3 `pread` instead of `seek` + `read`.** Removes the lock from the
read path entirely — the offset stops being shared state. Concurrent
reads then actually overlap.
*Done when*: the mutex is gone from `FileDevice::read_at` and 1.1 is
re-run.

**1.4 Readahead.** Only after 1.1–1.3, and only where the measurement
says sequential reads dominate. A guess here costs memory and buys
nothing.

---

## Tier 2 — what stops real use today

Each of these makes a volume usable that currently is not.

**2.1 XFS: more than one journalled write per mount.** Today a mount
gets one create, or one delete, or one rename, and then refuses. For a
volume in Finder that is not a limitation, it is a demo. Needs the
transaction path to read back its own uncommitted state rather than the
disk.
*Done when*: the feature matrix runs several journalled operations in
one mount and `xfs_repair` passes.

**2.2 XFS: log replay.** A volume that was not cleanly unmounted is
refused outright. That is the most common real-world state after a
crash or a yanked cable, and the kernel simply replays it.
*Done when*: a dirty fixture mounts, and its contents match what the
kernel sees after replaying the same image.

**2.3 NTFS: grow a directory past its index root.** `$INDEX_ALLOCATION`
insert and delete are not implemented, so creating a file in a large
directory fails.

**2.4 NTFS: grow `$MFT`.** A volume whose MFT is full cannot take a new
file.

---

## Tier 3 — feature parity, each its own project

**3.1 btrfs: the copy-on-write write path.** Everything except
`nodatacow` overwrite. The largest single item here; `docs/transaction-format.md`
in that repo has the shape.

**3.2 NTFS: compressed and sparse `$DATA`.** Reading handles
uncompressed runs and non-hole reads; the rest is refused.

**3.3 Extended attributes.** XFS documents the on-disk shapes and does
not read them; squashfs does not surface what it parses. macOS leans on
xattrs, so this is more visible here than on Linux.

**3.4 erofs: ZSTD.** One codec, well-bounded.

**3.5 btrfs: crossing into a subvolume by path.** `lookup_path("/sub/x")`
stops at the boundary. An inode number means nothing without its tree,
so crossing has to hand back both.

---

## What this list is not

It is not sized. No item here carries an estimate, because the two that
looked smallest this week — "free part of a shared extent" and "read a
group's trees" — each turned out to hide a measurement nobody had taken
(that the reverse map is an interval tree; that the free list logs as
buffer type 6). The order is by expected gain, and the next item is
chosen when the previous one lands.
