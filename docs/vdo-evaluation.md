# VDO support — evaluation and decision

**Date:** 2026-08-24
**Decision:** Not building VDO support. Revisit only if the trigger conditions below are met.
**Status:** Deferred indefinitely, not rejected on principle.

This document exists so the reasoning survives. The conclusion ("we're not doing VDO")
is easy to remember; the *reason* is not, and the reason is the part that determines
whether a future change in circumstances should reopen the question.

## What VDO is

VDO (Virtual Data Optimizer) is a Linux device-mapper target — `dm-vdo`, in the
mainline kernel since 6.9. It provides four things at the block layer:

- **Inline deduplication** — duplicate 4 KiB blocks are detected on write and stored
  once, with the second and subsequent writers holding a reference to the original.
  Sharing ratios up to 254:1 are supported.
- **Inline compression** — blocks are compressed with LZ4, and several compressed
  blocks are packed together into a single 4 KiB physical block.
- **Zero-block elimination** — all-zero blocks are recorded as metadata, never stored.
- **Thin provisioning** — the logical size can exceed the physical size.

It is genuinely a compression layer, which is how it is usually described. The
important qualifier is *where* it sits: **below the filesystem, not inside it**. The
deployed stack is `disk → LVM → VDO → XFS`. It is not a filesystem feature in the way
Btrfs compression is; it is a transformation applied to a block device, and the
filesystem above it is unaware it exists.

## Persistent structures

Four, per the kernel's design documentation:

| Structure | Role |
|---|---|
| Deduplication index (UDS) | Maps block hashes to previously-written blocks |
| Block map | Radix tree mapping logical block addresses to physical ones |
| Slab depot | Physical block allocation, reference counts, per-slab journals |
| Recovery journal | Records metadata updates so a crashed volume can be recovered |

One useful observation for any future attempt: **the deduplication index is write-side
only.** Its entire job is answering "have I seen this block's content before" on
behalf of a writer. A read-only implementation never consults it. A VDO *reader* needs
only the block map, the slab depot's physical mapping, and LZ4 decompression — which
removes the largest and least-documented component from the problem. If VDO is ever
revisited, start from that simplification rather than from the full design.

## How it would fit our architecture

This part is settled and is *not* the blocker. VDO composes cleanly with what we
already have.

`fs-core` already supports block-device-wrapping-block-device: `CachingDevice` holds
an `Arc<dyn BlockDevice>` and itself implements `BlockDevice`. `Qcow2Reader` implements
the same trait (`rust-img-qcow2/src/reader.rs:1166`). A VDO layer would be no different:

```
FSBlockDeviceResource
  → CallbackDevice     (fs-core)
  → partition slice    (am-partitions)
  → LvmDevice          (am-blk-lvm2)
  → VdoDevice          (am-blk-vdo)
  → XfsFilesystem      (am-fs-xfs)
  → FSVolume
```

### Ownership runs filesystem-first

A tempting but wrong mental model is "a VDO driver registers with FSKit and loads a
filesystem driver as a second stage". That cannot work, for two reasons:

1. An FSKit extension must produce an `FSVolume` — files and directories. A VDO layer
   has no files to present; it produces bytes. FSKit has no concept of an extension
   publishing a block device for other extensions to consume.
2. Nothing is loaded at runtime. Extensions are signed bundles and cannot `dlopen` a
   driver, least of all under the MAS sandbox. Composition is a static link resolved
   at build time.

So the registered driver is the **filesystem** extension, which links the block layers
beneath it and probes through them. This is the same conclusion already reached for
disk images in `fskit-disk-image-mount-architecture.md`, which selected Option α
(per-filesystem modules that understand containers) and explicitly rejected Option β
(a container module embedding every filesystem driver). The reasoning that killed
Option β kills a VDO-owns-XFS arrangement identically.

In practice this means block layers appear as extra dependencies in each per-extension
aggregator, exactly as the `am-img-*` crates already do in `dj-ext4-bundle`. The block
crates are duplicated across bundles; each extension stays self-contained.

### Probing

The real design work is probe, not layering. A filesystem inside VDO inside LVM has
LVM metadata at offset 0, not a filesystem superblock. Probe must walk the stack:
recognise the LVM label, parse the volume-group metadata, enumerate logical volumes,
then probe each for a filesystem we support. Any block layer we adopt becomes a
dependency of *every* filesystem bundle, because any filesystem might be found beneath it.

## Why we are not building it

**There is no bit-level format specification, and the only remaining source is
GPL-licensed kernel code.**

The mainline design document (`Documentation/admin-guide/device-mapper/vdo-design.rst`)
was reviewed directly. It describes architecture and theory of operation. It names the
four persistent structures and gives occasional concrete details ("each entry is
5 bytes"), but it contains:

- no bit-level layout for any structure
- no journal entry format
- no block map or tree node layout
- no serialization, alignment, or encoding rules

Its own framing is that an implementer would need specifications "likely found in
source code". That is precisely the position we will not put ourselves in. Reading the
kernel implementation to recover the format would make our result a derivative of
GPL code, which is disqualifying for a project distributed under MIT through the
App Store.

This is what separates VDO from the other formats we have taken on:

| Format | Specification available | Outcome |
|---|---|---|
| ext4, XFS | Detailed public format documentation | Built / building |
| qcow2, VMDK, VHD, VHDX | Published format specifications | Built |
| Btrfs | Format documentation plus an MIT-licensed reference implementation (Haiku) | Building |
| LVM2 | Plain-text on-disk metadata, fully documented | Viable, not yet started |
| **VDO** | **Architecture prose only** | **Blocked** |

Note that the blocker is licensing and documentation, not difficulty and not
architecture. The architecture question is answered above and the answer is favourable.

## Secondary costs

Even with a specification, VDO would carry costs worth recording:

- **LVM2 is a prerequisite.** VDO volumes are normally created as LVM logical volumes
  (`lvcreate --type vdo`). Reaching one means parsing LVM2 metadata first. That is a
  separate body of work.
- **A recovery journal must be replayed.** Unlike the disk-image container formats,
  which have no journal, a VDO volume that was not cleanly shut down cannot be trusted
  until its recovery journal is applied. This is filesystem-driver-shaped work, not
  container-reader-shaped work.
- **The audience is enterprise storage.** VDO is a server and datacentre technology.
  Portable media formatted with VDO and plugged into a Mac is not a scenario we have
  evidence of.

## What would reopen this

Any one of:

1. A published bit-level format specification for the block map and slab depot, from
   any source that is not GPL-licensed implementation code.
2. A permissively-licensed (MIT/BSD/Apache) implementation appearing that we could
   port from, as Haiku's drivers make Btrfs and XFS viable.
3. Concrete user demand — actual reports of VDO-formatted media that users want to
   read on macOS.

Absent those, the position stands.

## The better adjacent target: LVM2

While evaluating VDO, a more valuable gap surfaced. **DiskJockey cannot currently read
any filesystem inside an LVM volume.** Linux external drives are frequently
LVM-formatted, and today those present as unrecognised media regardless of which
filesystem is inside.

LVM2 is the opposite of VDO on every axis that matters:

- Its on-disk metadata is **plain text** — a label header near the start of the device,
  a PV header, then a metadata area containing a human-readable volume-group
  description listing logical volumes and their segment mappings.
- It is fully documented, with no reverse engineering required.
- Linear and striped segment mapping is straightforward arithmetic.
- It unblocks a user-visible category of media immediately.

If a block-layer crate is to be built, `am-blk-lvm2` is the one worth building. It is
also a prerequisite for VDO, so nothing is wasted if VDO ever becomes viable.

One open question to settle before starting it: a volume group can contain several
logical volumes, each with its own filesystem. For disk images the multi-partition case
was solved with a URL fragment (`file:///disk.qcow2#part=2`) and one mount per resource.
A physical LVM disk arrives as an `FSBlockDeviceResource` with no URL to carry an
equivalent `#lv=home` selector. Either the host app enumerates and drives N mounts, or
we need FSKit's multiple-volumes-per-container path. This changes the extension's shape
and should be decided before implementation, not during.

## Crate naming

VDO raised the question of where such a crate would live, and the answer generalises.
Crates are named for **what the thing is**, never for what interface it exposes — every
crate in the fleet exposes or consumes `BlockDevice`, so that axis carries no
information.

| Prefix | What it is | Members |
|---|---|---|
| `fs-*` | A filesystem — files, directories, inodes | ext4, ntfs, erofs, squashfs, xfs, btrfs |
| `img-*` | A disk image file format — a file containing a disk | qcow2, vhd, vhdx, vmdk |
| `blk-*` | A transformation over real storage, found by probing | lvm2, vdo, dm-crypt, mdraid (none built) |
| bare | A utility that is none of the above | partitions, lzo1x, fs-core |

The `img-*` crates share machinery with VDO — indirection tables, sparseness,
compression — but shared mechanism does not merge categories. No existing crate should
be renamed; crates.io names are permanent, and the current names are accurate.
