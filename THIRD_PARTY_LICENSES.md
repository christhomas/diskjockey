# Third-Party Licenses

DiskJockey is MIT-licensed (see `LICENSE`). This file enumerates the
licenses of every component statically linked into the shipped binary,
for compliance with their respective notice requirements.

## Rust crates linked into the shipped binary

Each FSKit extension links one aggregator static library from
`rust-bundles/`, which depends on the crates below. They are published
to crates.io rather than vendored, so the version linked is whatever
that bundle's `Cargo.toml` pins.

| Crate | License | Source |
|---|---|---|
| `am-fs-core` | MIT | github.com/antimatter-studios/rust-fs-core |
| `am-fs-ext4` | MIT | github.com/christhomas/rust-fs-ext4 |
| `am-fs-ntfs` | MIT OR Apache-2.0 | github.com/christhomas/rust-fs-ntfs |
| `am-fs-xfs` | MIT | github.com/antimatter-studios/rust-fs-xfs |
| `am-fs-btrfs` | MIT | github.com/antimatter-studios/rust-fs-btrfs |
| `am-fs-erofs` | MIT | github.com/antimatter-studios/rust-fs-erofs |
| `am-fs-squashfs` | MIT | github.com/antimatter-studios/rust-fs-squashfs |
| `am-img-qcow2` | MIT | github.com/antimatter-studios/rust-img-qcow2 |
| `am-img-vhd` | MIT | github.com/antimatter-studios/rust-img-vhd |
| `am-img-vhdx` | MIT | github.com/antimatter-studios/rust-img-vhdx |
| `am-img-vmdk` | MIT | github.com/antimatter-studios/rust-img-vmdk |
| `am-lzo1x` | MIT | github.com/antimatter-studios/rust-lzo1x |
| `am-partitions` | MIT | github.com/antimatter-studios/rust-partitions |

## Other direct components

| Component | License | Source |
|---|---|---|
| `go-networkfs` | MIT | github.com/christhomas/go-networkfs |
| `diskprobe` | MIT | first-party, `vendor/rust-disk-probe` |
| `tabler-icons` | MIT | github.com/tabler/tabler-icons |

## Transitive Rust dependencies

Every crate above resolves a closure that is entirely MIT, Apache-2.0,
BSD, Zlib, ISC, 0BSD, CC0-1.0, MIT-0 or Unicode-3.0. **No copyleft
appears in any Rust dependency tree.** Reproduce with `cargo metadata`
in each crate and read the `license` field of every package.

One entry looks like a copyleft hit and is not: `r-efi` declares
`MIT OR Apache-2.0 OR LGPL-2.1-or-later`. The licence is disjunctive, so
MIT applies; it is a dev-dependency of `tempfile` only; and it is gated
to UEFI targets, so it is never built here.

## Transitive Go dependencies (go-networkfs)

The Go drivers pull a large transitive closure across MIT / BSD / ISC / Apache-2.0.

**No copyleft.** Two MPL-2.0 modules — `hashicorp/errwrap` and `hashicorp/go-multierror`
— used to be here, reached through the FTP driver's client library. They no longer ship:
that client was replaced with `github.com/antimatter-studios/goftp`, which depends on
nothing outside the Go standard library.

```
$ go list -deps ./... | grep -c hashicorp
0
```

## Forks maintained for this project

Two dependencies are forks. Both keep their upstream's licence unchanged, and both carry
our changes as pull requests offered upstream rather than as private divergence.

| Component | License | Fork of | Why |
|---|---|---|---|
| `antimatter-studios/goftp` | MIT | `secsy/goftp` | needed a dial hook for byte counting; the previous client pulled in MPL-2.0 |
| `antimatter-studios/go-smb2` | BSD-2-Clause | `hirochachacha/go-smb2` | GO-2026-5051, which upstream records as having no fix |

The SMB fix is Arash Payan's, backported from `cloudsoda/go-smb2` (also BSD-2-Clause).

## Per-driver SDK licenses (network filesystem clients)

The `go-networkfs` drivers wrap protocol SDKs with these licenses:

| Driver | SDK / library | License |
|---|---|---|
| FTP | `jlaffaye/ftp` | ISC |
| SFTP | `pkg/sftp` + `golang.org/x/crypto` | BSD-2-Clause + BSD-3-Clause |
| SMB | `hirochachacha/go-smb2` | BSD-2-Clause (transitive MPL noted above) |
| Dropbox | `dropbox/dropbox-sdk-go-unofficial` | MIT |
| WebDAV | `studio-b12/gowebdav` | BSD-3-Clause |
| Google Drive | `google.golang.org/api` (raw REST) | BSD-3-Clause |
| Amazon S3 | `aws/aws-sdk-go-v2` | Apache-2.0 |
| OneDrive | Microsoft Graph (raw REST) | BSD-3-Clause client |

## Spec sources cited in code

The pure-Rust filesystem drivers were written from public on-disk
format specifications, **not** derived from any GPL-licensed prior-art
codebase. Spec sources cited in source comments:

- ext4 on-disk format — kernel.org/doc/html/latest/filesystems/ext4/
- NTFS on-disk format — Microsoft public specifications + reverse-
  engineered structural references; cross-validated against Microsoft's
  own `chkdsk` for correctness
- Brian Carrier, *File System Forensic Analysis* (Addison-Wesley, 2005)
  — chapter 14 (ext) and chapter 12 (NTFS)

## Updating this file

When a vendor submodule pointer is bumped, the corresponding entry
above should be reviewed for license-mix changes. New MPL-or-restrictive
deps appearing in `go-networkfs` `go.sum` should be added to the
"Transitive Go dependencies" section before release.
