# Human-code report — 2026-08-24

**Scope:** the three new filesystem crates — `rust-lzo1x`, `rust-fs-xfs`, `rust-fs-btrfs`.
Files reviewed: `rust-lzo1x/src/lib.rs`, `rust-fs-xfs/src/{superblock,ag,inode,error}.rs`,
`rust-fs-btrfs/src/{superblock,chunk,error}.rs` — 5,554 lines.

**Counts:** 6 items found, 6 fixed, 2 deliberately skipped.

Two modules (`rust-fs-xfs/src/dir.rs`, `rust-fs-btrfs/src/btree.rs`) were being written
concurrently and were excluded; they need a separate pass.

---

## Changes made

### H1 — Byte-order helpers duplicated across three modules

**Files:** `rust-fs-xfs/src/endian.rs` (new), `src/superblock.rs`, `src/ag.rs`, `src/inode.rs`

`be16`, `be32` and `be64` existed as private copies in three modules — eight identical
function bodies, with nothing forcing them to agree.

```rust
// before — repeated verbatim in superblock.rs, ag.rs and inode.rs
fn be32(b: &[u8], off: usize) -> u32 {
    u32::from_be_bytes([b[off], b[off + 1], b[off + 2], b[off + 3]])
}

// after — one definition, imported everywhere
use crate::endian::{be16, be32, be64, le32, uuid_at};
```

**Why it's better:** this is the highest-severity item in the review because it sits
exactly where the crate has already been wrong. XFS is big-endian except for checksum
fields, which are little-endian — a rule that has cost this driver three shipped bugs.
Three private copies meant a single one could quietly switch to `from_le_bytes` and
still pass every test, because the hand-built fixtures would be written with the same
mistake. One definition removes the opportunity, and the module documents the rule once
rather than three times. A new test asserts the big-endian and little-endian readers
return *different* values for the same bytes — if they ever agree, one is wrong.

### H2 — 83 unnamed numeric offsets in the parse paths

**Files:** `rust-fs-xfs/src/superblock.rs`, `src/ag.rs`, `src/inode.rs`

```rust
// before
rootino: be64(buf, 56),
agblklog: buf[124],
features_incompat: be32(buf, 216),

// after
rootino: be64(buf, offsets::ROOTINO),
agblklog: buf[offsets::AGBLKLOG],
features_incompat: be32(buf, offsets::FEATURES_INCOMPAT),
```

Each structure gained a documented `offsets` module naming every field it reads.

**Why it's better:** a numeric literal inside a parse expression gives a reader no way
to distinguish a correct offset from a typo — and two of the three bugs this crate has
shipped were precisely that (a transposed magic constant, and a checksum computed over
the wrong span). A name can be checked against the format documentation by eye; `56`
cannot. This also brings XFS in line with the convention the sibling Btrfs driver
already followed, which matters given the requirement that the crates stay in sync.

**Verified against real media, not merely recompiled.** After rewriting all 83 offsets,
all five cross-validation tests still pass — 342 field comparisons against `xfs_db`
across nine real filesystems. A refactor of this shape could easily have introduced the
exact defect class it was meant to prevent, so proving it did not was part of the work.

### M3 — `Superblock::parse` mixed five abstraction levels over 129 lines

**Files:** `rust-fs-xfs/src/superblock.rs`

Checksum verification and the incompatible-feature gate were extracted into
`verify_checksum` and `reject_unsupported_features`, each carrying the reasoning that
was previously an inline comment.

**Why it's better:** the extracted functions have names that state their purpose, and
the non-obvious constraint — that the checksum covers the whole sector rather than the
264-byte struct — now lives on the function that enforces it rather than buried
mid-parse. The remaining length is a flat field mapping, which is left alone: splitting
a straight-line struct literal would add indirection without adding clarity.

### M4 — `Superblock::validate` covered four unrelated concerns in 108 lines

**Files:** `rust-fs-btrfs/src/superblock.rs`

Split into `validate_geometry`, `validate_tree_roots`, `validate_sys_chunk_array` and
`validate_device_identity`.

**Why it's better:** the name of the failing check now tells a reader which class of
problem they have. Previously any of a dozen unrelated conditions produced a generic
`BadSuperblock`, and locating the relevant check meant reading the whole function.

### M5 — Unexplained defensive cap in the decode loop

**Files:** `rust-lzo1x/src/lib.rs`

```rust
// before
if len > (1 << 24) {

// after
const MAX_EXTENDED_LENGTH: usize = 1 << 24;
if len > MAX_EXTENDED_LENGTH {
```

**Why it's better:** this was the one literal in the crate that genuinely needed a name.
Nothing at the call site said whether 16 MiB was a format limit or a safety valve — it
is the latter, and the grammar permits arbitrarily long runs. Without the cap an
all-zeros input loops until the length overflows. The constant's documentation now says
which of those it is, so a future reader does not "fix" it by raising it to match some
imagined format maximum. Three grammar constants (`255`, `16384`, `2049`) were named at
the same time.

### L6 — Packed-struct offset that reads as a typo

**Files:** `rust-fs-btrfs/src/chunk.rs`

`DiskKey::parse` reads its third field at byte 9, immediately after a `u8` at byte 8.
A comment now records that the key is a packed 17-byte record with no padding, because
reading it as an aligned struct would land three bytes into the wrong field.

---

## Items skipped

| Item | Reason |
|---|---|
| Five bare offsets in `chunk.rs`'s `DiskKey`/`Stripe` parsers | *Acceptable pattern* — two small structs whose fields are read on adjacent lines. Naming `0`, `8` and `9` there adds indirection without adding clarity, unlike the 83 scattered across XFS's large structures. |
| `Superblock::parse` remaining length in both crates | *Acceptable pattern* — what remains is a flat field-to-field mapping at a single abstraction level. Splitting a struct literal makes it harder to check against the format documentation, not easier. |

## Test results

| | Before | After |
|---|---|---|
| `rust-lzo1x` | 11 unit + 6 oracle + 1 doctest | 11 unit + 6 oracle + 1 doctest |
| `rust-fs-xfs` | 34 unit + 5 cross-validation | **39** unit + 5 cross-validation |
| `rust-fs-btrfs` | 75 unit + 2 integration + 3 oracle | 75 unit + 2 integration + 3 oracle |
| Failures | 0 | 0 |
| Clippy (`-D warnings`) | clean | clean |

Five tests were added, all in the new `endian` module, including one asserting that the
big-endian and little-endian readers disagree on the same input.

No behaviour changed. The cross-validation suites — 342 XFS field comparisons against
`xfs_db` and 216 Btrfs comparisons against `dump-super`, across eighteen real
filesystems — pass identically before and after.

## Follow-up

`rust-fs-xfs/src/dir.rs` and `rust-fs-btrfs/src/btree.rs` were written concurrently with
this review and were not covered. `rust-fs-btrfs` also still keeps its byte-order
helpers inside `superblock.rs` rather than a dedicated `endian` module as XFS now does;
aligning the two is worth doing once the concurrent work has landed, since the crates
are meant to stay structurally in step.
