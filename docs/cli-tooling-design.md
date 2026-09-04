# CLI tooling: naming, packaging and distribution

Decided 2026-08-31. This records the reasoning as well as the decisions,
because most of the choices below look arbitrary from the outside and
several of them went *against* the obvious answer for a measured reason.

Nothing here is built yet. It exists so that when the formatters land,
the surface they get is decided rather than improvised.

---

## What these are for

**Filesystem operations on a disk image or a raw device, without
mounting it.**

That is the whole pitch, and it is worth stating before the naming
argument, because the naming argument is downstream of it.

On Linux this need barely exists: `mount -o loop disk.img /mnt` and then
`ls`, `cp` and `rm` do the job, because the kernel has drivers for all
of these formats. On macOS it does not. There is no loop mount for ext4,
NTFS, XFS or Btrfs — which is the reason this project exists at all — so
"look inside this image" has no answer short of installing a filesystem
extension, or booting a Linux VM to do it.

These tools read and write the image **directly**. No mount, no kernel
driver, no root, no FSKit extension, no VM. The same code path serves a
raw device (`/dev/diskN`, `\\.\PhysicalDriveN`) as serves a file,
because to a driver both are just bytes at offsets.

Which is also why the read verbs matter more than `mkfs`, and why they
come first: someone can borrow a Linux box to *create* a filesystem, but
"read this disk that will not mount" is the thing they installed this
for, and it is the thing macOS offers nothing for.

---

## The problem

Given that, the question is what to call them — and the Linux toolset is
an object lesson. It has one consistent name and dozens of
inconsistent ones. Four filesystems, four separate vocabularies for the
same concepts:

| concept | ext4 | xfs | btrfs | ntfs |
|---|---|---|---|---|
| create | `mkfs.ext4` | `mkfs.xfs` | `mkfs.btrfs` | `mkfs.ntfs` |
| check | `fsck.ext4` | `xfs_repair` | `btrfs check` | `ntfsfix` |
| inspect | `dumpe2fs` | `xfs_info` | `btrfs fi show` | `ntfsinfo` |
| label | `e2label` | `xfs_admin -L` | `btrfs fi label` | `ntfslabel` |
| resize | `resize2fs` | `xfs_growfs` | `btrfs fi resize` | `ntfsresize` |

Only `mkfs.*` is consistent, and only because a dispatcher forced it.
Everything else is four unrelated projects' folklore, accumulated over
decades.

We are writing all of these from scratch, in one family, over a shared
`fs-core`, with C APIs that already expose the same verbs. There is no
reason to reproduce the fragmentation.

---

## Why we write our own rather than porting

Worth recording because it is the question everyone asks first.

The *format* is host-independent — a formatter opens a file, writes
bytes, closes it, and no kernel driver is involved. That is why our Rust
formatters already run on macOS and produce images Linux mounts.

The *upstream programs* are not portable as written:

- there is no macOS package for the xfs userspace tools at all;
- the btrfs userspace formula is `depends_on :linux` and pulls in
  `systemd` (libudev) and `util-linux`.

They are built against Linux headers, Linux ioctl numbers and `/sys`
device enumeration; the xfs userspace library is the kernel's own XFS
code shimmed out. Porting is a project, not a `./configure && make`.

And a successful port still would not ship, for two independent reasons
either of which is fatal on its own:

- **Licence.** Both are GPL-2.0. We do not link GPL.
- **Sandbox.** A MAS app cannot `NSTask` a bundled executable.
  Formatting works today because it is a framework call into the FSKit
  extension.

Running them in a VM at runtime fails both tests as well. Where they
*are* useful is as **test oracles at arm's length** — a separate
process, no linking, no copying. That is the contract `mkfs_ext4` has
with the ext4 checker and `mkfs_erofs` has with the erofs checker in CI,
and it is unaffected by any of the above.

---

## Naming

### The dot means "dispatcher backend", and the direction matters

`mkfs.ext4`, `fsck.xfs` and `mount.nfs` are all `<verb>.<filesystem>`.
`mkfs(8)` literally builds the string `mkfs.xfs` and execs it. The dot
is a separator a front-end constructs, not a style choice.

So `<filesystem>.<verb>` — `btrfs.amctl` — is backwards, and reads as a
misuse of the convention rather than a use of it. Anything of ours that
is not in a dispatcher family uses a hyphen instead.

Evidence for how narrow the convention is: e2fsprogs ships **30
binaries, exactly 6 dotted**, and those 6 are precisely
`mkfs.ext{2,3,4}` and `fsck.ext{2,3,4}`. Every other binary in the same
package uses that package's house style. Note also `mksquashfs`,
`mkswap` and `mkisofs` — "always dot" would be wrong.

### The verb goes before the dot, and every tool has the same shape

```
<verb>.<fs>  <target>  [args…]
```

```
mkfs.ext4    disk.img
fsck.ext4    disk.img
info.ext4    disk.img
ls.ext4      disk.img /the/subdirectory
read.ext4    disk.img /path/to/file          # stdout, or -o out.bin
write.ext4   disk.img /path/to/file < input
get.ext4     disk.img label
set.ext4     disk.img size 20G
```

### `read`/`write`, not `cat`

An earlier draft had `cat.ext4`, and the asymmetry is probably why this
set had no write verb at all until someone noticed: `cat` has no natural
inverse. `tee.ext4` is not a name anyone would guess, so the write side
simply never got named — while `am-fs-ext4`, `am-fs-ntfs` and
`am-fs-xfs` all have write paths, and `rust-ntfs` already ships `write`,
`touch`, `mkdir`, `rm`, `rmdir`, `rename` and `link`.

Two smaller objections point the same way. `cat` means *concatenate*,
and we would only ever pass one file. And it bakes the destination into
the name: the operation is "read this file", of which stdout is one
possible sink alongside `-o` or a pipe.

`ls` survives the same test — listing a directory is exactly what `ls`
means. `cat` does not.

The precedent argument is real and does not carry it: `ntfscat` ships
and `debugfs` has a `cat` command. But this scheme's whole claim is one
uniform vocabulary rather than twenty years of drift, and borrowing
shell idioms piecemeal is how that drift begins.

The namespace verbs the drivers already implement follow the same rule —
name the operation, in matched pairs where one exists:

```
mkdir.ext4  disk.img /new/dir
rm.ext4     disk.img /path
mv.ext4     disk.img /from /to
ln.ext4     disk.img /target /link
touch.ext4  disk.img /path
```

**The target is always the first argument.** `mkfs.*` and `fsck.*`
already work that way, so extending it costs nothing and means the disk
is never in a different position depending on which tool you reached
for.

Rejected alternative: a *category* before the dot with verbs as
subcommands (`inspect.ext4 ls …`). It reintroduces exactly the
inconsistency we are removing — some tools would take a subcommand and
some would not, inside one namespace.

### Names are free; binaries are not

The full matrix is 4 filesystems × ~6 verbs ≈ 24 names, which sounds
expensive and is not: it is **one multi-call binary dispatching on
`argv[0]`**, installed under every name. Busybox works this way, and so
does e2fsprogs — which is why `mkfs.ext4` shows a link count of 2 on an
installed copy.

Consequences worth keeping:

- adding a verb is one more link per filesystem that supports it;
- **partial support is expressed by the link's absence.** If xfs cannot
  resize yet, `resize.xfs` does not exist, and `resize.<TAB>` tells the
  truth at completion time rather than as a runtime failure.

### No `mkfs` dispatcher of our own

Declining it *removes* risk rather than just declining a feature. A bare
`mkfs` on PATH is the worst possible collision candidate — it shadows
the front-end everything else on a Linux box routes through — for
almost no ergonomic gain, since `mkfs.ext4 disk.img` is already shorter
than `mkfs -t ext4 disk.img`. It stays available later; adding it is
purely additive.

### No generic `dj` binary

Rejected after being proposed twice, on the grounds that it is a **layer
confusion**: the CLI tools are the domain layer and are useful to
someone who never installs the app, while DiskJockey is the brand layer
on top. `udisksctl` is not called `gnome-udisksctl` even though GNOME is
its main consumer. `dj` is also a poor command name in its own right —
two letters, says nothing about disks, and collides readily.

Nothing needs to replace it. The identification step already exists as a
domain-named tool:

```
diskprobe /dev/disk4          → ext4
ls.ext4   /dev/disk4 /etc
```

Two commands, both honest, and nothing is ever inferred wrongly on a
mutating verb.

**Package names are a different layer.** `diskjockey-btrfs` as a
*formula* is fine — packages are routinely vendor-named and no formula
name lands on anyone's PATH. Only what lands in `bin/` must be
domain-named.

### Cargo cannot produce a dotted name

Tested: `error: invalid character '.' in crate name`. So the cargo
target keeps an underscore (`mkfs_ext4`) and the **release step**
renames it, so the published tarball carries the real name. Renaming in
the formula instead would leave the build-system artefact visible in a
public artifact.

---

## The interface contract

Names are the visible half. The half that matters is that all four
filesystems answer the same way.

1. **Same verb set.** Every filesystem implements every verb. A verb
   that is not yet supported returns "not implemented" rather than the
   name being absent from the *interface* — so a script moved between
   filesystems fails loudly instead of silently meaning something else.
   (The *link* may be absent; that is the packaging-level signal. The
   two are different layers.)

2. **Same flags for the same concepts** — `--label`, `--size`,
   `--force`, `--json`, `--quiet`. This is where Linux fails worst: `-L`
   happens to agree across the three formatters, but `-f`, `-n` and `-b`
   all diverge.

3. **Same output envelope.** Common fields at the top, filesystem
   specifics nested:

   ```json
   { "fs": "ntfs", "label": "…", "total_bytes": …, "free_bytes": …,
     "block_size": …, "dirty": false,
     "ntfs": { "mft_total_records": …, "serial_number": "…" } }
   ```

   This is not invented. It is already the shape ntfs returns — its
   volume info carries `label`, `total_size`, `free_clusters`,
   `cluster_size`, `dirty` alongside `mft_*`, `serial_number` and
   `ntfs_version_*`. It needs naming and enforcing, not designing.

4. **Same exit codes.** `fsck.*` follows the scheme scripts already
   depend on — 0 clean, 1 corrected, 4 uncorrected, 8 operational error.

5. **Properties are a namespace, not a verb each.** Linux invented
   `e2label`, `xfs_admin -L`, `ntfslabel`, `tune2fs -U` and
   `btrfs filesystem label` for one concept. Instead:

   ```
   get.ext4 disk.img label
   set.ext4 disk.img label "Backup"
   set.ntfs disk.img dirty false
   ```

   A new property is a new key, not a new command. ntfs already
   implements `set_volume_label`, `read_volume_label`, `is_dirty` and
   `clear_dirty`, so this has working code behind it today.

   **Size is a property too, so there is no `resize` verb.** An earlier
   draft had one, which was this document making the exact mistake it
   criticises one paragraph earlier: Linux has `resize2fs`,
   `xfs_growfs`, `ntfsresize` and `btrfs filesystem resize` for one
   concept, the same way it has four spellings of "label".

   ```
   set.ext4 disk.img size 20G
   ```

   One caveat that has to be written down rather than glossed: every
   other property here is a field write and returns instantly, whereas
   setting `size` relocates data, can take minutes and can fail partway.
   Sitting in a namespace of cheap operations makes it look cheaper than
   it is. That is answered by requiring `--force` and by saying so in
   the help, not by giving it a verb of its own — a separate verb would
   not make it any less expensive, only harder to find.

   **`info` is NOT folded into `get`**, though it looks like the same
   family. They have different output contracts: `info` dumps the whole
   envelope as JSON, `get` returns one bare value so
   `$(get.ext4 disk.img label)` works in a script. Merging them means
   one of those two uses gets a worse answer.

**Enforcement:** the verb set, flag vocabulary and output envelope live
in a shared crate that each filesystem *fills in*. A new filesystem then
cannot invent its own dictionary, because there is nowhere to put one.
This is the same move as the rest of the family — one definition rather
than four copies that agree by inspection. The Linux toolset is exactly
what four copies look like after twenty years of drift.

---

## Distribution

### Homebrew, not direct download

Quarantine is applied by browsers and AirDrop, not by curl, so a
brew-installed tarball runs **without notarisation**. A direct download
from the website would be quarantined and would need it. That decides
the channel on its own.

The tap already exists: `antimatter-studios/homebrew-tap`.

### One tap, formulae named per repo

The binaries are built and released from each filesystem's own repo; the
*formulae* all live in the one existing tap. Six taps would mean six
`brew tap` commands before anything is installable.

Formulae are named for the **repo**, not for one binary —
`diskjockey-btrfs`, not `mkfs-btrfs` — because a repo grows tools and a
binary-named formula goes stale the moment it ships a second one. The
ecosystem agrees: e2fsprogs is one formula shipping 30 binaries.

House idiom for this tap is **prebuilt per-platform tarballs from GitHub
Releases** with sha256 (see `chore.rb`), not build-from-source. Tarballs
are named for the crate — `am-fs-btrfs-0.6.0-darwin-arm64.tar.gz` —
with the dotted binary inside: artifact named for the source, binary
named for the user, and no extra dot for a filename parser to trip over.

Every repo's current `release.yml` is crates.io publish only, so emitting
binary tarballs is new work in each. It should be **one reusable
workflow** called with a binary name, not seven copies of the same YAML.

### Linking: macOS yes, Linux keg-only

| platform | linked | why |
|---|---|---|
| macOS | yes | nothing to shadow — no `mkfs` dispatcher exists, and no `mkfs.*` ships in the base system |
| Linux | **keg-only** | the real tools exist and should win by default |

The Linux hazard is not hypothetical and is not solved by declining to
write a dispatcher: `mkfs -t ext4` works on any Linux box because
util-linux's `mkfs` is already there, and it resolves `mkfs.ext4` off
PATH regardless of our intentions. Leaving it to PATH ordering means the
outcome depends on how a user's shell happens to be configured, and the
failure mode is someone formatting a real disk with our implementation
while believing they ran the mature one. That is a race worth not
entering.

Precedent, in our own dependency tree: Homebrew ships e2fsprogs
`keg_only`, which is why `mkfs.ext4` is present on a Mac with it
installed and still absent from PATH.

It is a default, not a lock-in — `brew unlink` and `brew link --force`
both work. And you can add a name later; you cannot take one away, so
ship the minimal set.

### The umbrella

`diskjockey-tools` (preferred over `diskjockey-cli`, which reads as
"the CLI version of DiskJockey" — a thing we are explicitly not
building) is a pure meta-formula: `depends_on` lines and no binaries of
its own.

It keeps one job on Linux: because the leaves are keg-only there, it
collects symlinks into a single directory so there is **one** PATH line
instead of six. Symlink to each leaf's `opt_bin`, never to the Cellar
path — `opt` follows the current version, so the umbrella survives leaf
upgrades untouched.

It must be keg-only on Linux too. A linked umbrella symlinking
everything would put `mkfs.ext4` back on PATH and undo the whole reason
the leaves are keg-only.

```console
# macOS
brew install antimatter-studios/tap/diskjockey-tools     # done

# Linux
brew install antimatter-studios/tap/diskjockey-tools
export PATH="$(brew --prefix diskjockey-tools)/bin:$PATH"
```

---

## The `diskjockey` control CLI — separate, and last

Distinct from everything above: a CLI that talks to the **app**, not to
filesystems. Branded correctly, because the brand is its subject —
`docker` controls the Docker daemon, `systemctl` controls systemd.

The transport already exists. `com.antimatterstudios.diskjockey.agent`
is a registered Mach service and `DJAgentClient.swift` already connects
to it with `NSXPCConnection(machServiceName:)`. It vends `attachImage`,
`detachDevice`, `mountFSKit` and `probeImage` — all operations a
sandboxed app cannot perform itself, which is why the agent exists. The
`diskjockey://` URL scheme is the other channel but is fire-and-forget,
so it is useless for scripting.

Two properties make it worth building:

- the agent is a **LaunchAgent**, so a scripted call works whether or
  not the GUI is running — the CLI talks to the same service the GUI
  talks to, rather than driving the GUI;
- it can answer things nothing else can. FSKit extension enable-state is
  read via `pluginkit`, which the sandboxed app cannot do — so there is
  currently no way to ask from a script at all.

**One constraint to solve first.** Both ends call
`setCodeSigningRequirement` — the client validates the agent *and* the
agent validates its caller. A brew-installed `diskjockey` binary is
rejected unless it is Developer ID signed and the agent's requirement
admits it (Team ID rather than the app's bundle ID alone).

That produces an asymmetry which is itself a reason to keep these as
separate packages:

| | signing | pipeline |
|---|---|---|
| `mkfs.*`, `fsck.*`, `diskprobe` | none — nothing validates them | plain cross-compile + tarball |
| `diskjockey` | Developer ID required | signed build, cert in CI |

The filesystem tools stay trivially portable; only the control CLI
inherits Apple's machinery.

---

## Current state

| repo | ships today | planned |
|---|---|---|
| rust-fs-ext4 | `mkfs_ext4` | rename to `mkfs.ext4` |
| rust-fs-erofs | `mkfs_erofs` | rename to `mkfs.erofs` |
| rust-fs-ntfs | `rust-ntfs` (**test-harness driver**) | `mkfs.ntfs` added |
| rust-fs-squashfs | `lssquashfs` | fold into the verb scheme |
| rust-blk-probe | `diskprobe` | already correctly named |
| rust-img-qcow2 | `qcow2_tool` | rename — `_tool` says nothing |
| rust-img-vhd | `vhd_tool` | rename |
| rust-fs-xfs | — | **mkfs deferred — see below**; read verbs first |
| rust-fs-btrfs | — | **mkfs deferred — see below**; read verbs first |

### Why `mkfs.xfs` and `mkfs.btrfs` are deferred — measured 2026-09-04

Neither crate can format, and that is not a wrapper away. Worth stating
precisely, because both look far closer than they are.

`am-fs-xfs` has `super_write`, `group_write`, `log_write`, `create`,
`alloc_btree`, `inode_btree` and `dir_write`. `am-fs-btrfs` has
`super_write`, `tree_write`, `extent_write`, `commit` and `transaction`.
Read as a file list, that is most of a formatter.

It is not, because **every one of those modules edits a filesystem that
already exists.** `group_write`'s public surface is `rebuild_leaf`,
`rebuild_inode_leaf`, `changed_chunks`, `restamp_crc` — each takes the
buffer it is amending. `create` makes a file inside a transaction on a
mounted volume. Nothing in either crate computes an *initial layout*:
allocation-group count and size, empty allocation and inode btrees, the
root inode, an initialised log.

The one exception is the XFS superblock, modelled field by field and
buildable from nothing. That is the first of roughly six pieces, not
the last.

Confirming it from the other direction: neither crate has a
`format_filesystem` or `build_image` entry point. `am-fs-ext4`,
`am-fs-ntfs` and `am-fs-erofs` each do, and their `mkfs.*` binaries are
thin wrappers around exactly that one function.

**So: defer.** The ordering note below is the second reason rather than
an afterthought. `ls.xfs`, `read.xfs` and `info.xfs` are wrappers over
`mount`, `dir_*`, `read_file`, `stat` and `get_volume_info` — all of
which exist in both crates today. `mkfs.xfs` is a new subsystem.
Someone can borrow a Linux box to *create* an XFS filesystem; they
installed this to read one that will not mount.

`rust-ntfs` is **not** a formatter: it is the driver
`fs-test-harness.toml` invokes to exercise write paths inside the
Windows VM, with eleven subcommands. Renaming it would churn the harness
config, the VM protocol docs and the test matrix for no user-facing
gain. Add a separate thin `mkfs_ntfs` calling the same
`format_filesystem()` entry point, and leave `rust-ntfs` unshipped.

Ordering note: `fsck` and the read verbs are **cheaper than `mkfs` and
arguably more valuable**. Every crate already exposes `mount`, `dir_*`,
`read_file`, `stat` and `get_volume_info`, and ext4 and ntfs already
have `fsck` implementations. Someone can borrow a Linux box to *create*
a filesystem; "read this disk that will not mount" is why they installed
DiskJockey, and macOS offers nothing for it.

## Still open

- House style for tools with no dispatcher convention — `lssquashfs`,
  `qcow2_tool`, `vhd_tool`. The tap leans short and lowercase
  (`chore`, `ddt`, `dotman`, `tacli`); `diskprobe` already fits.
- Whether the image formats (qcow2, vhd, vhdx, vmdk) join the same verb
  scheme — `info.qcow2`, `ls.qcow2` — or stay separate tools.
