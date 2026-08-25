//
// DiskJockeyXFS-Bridging-Header.h
// Bridging header exposing the fs_xfs C ABI to Swift.
// Static lib vendored under vendor/rust-fs-xfs/, built to lib/fs_xfs/.
// Upstream: github.com/antimatter-studios/rust-fs-xfs
//

#ifndef DISKJOCKEY_XFS_BRIDGING_HEADER_H
#define DISKJOCKEY_XFS_BRIDGING_HEADER_H

#import "fs_xfs.h"

// fs_core.h ships alongside fs_xfs.h (same include dir). Its symbols
// (fs_core_device_from_callbacks, fs_core_device_slice_ro, …) are linked
// into libfs_xfs.a via the am-fs-core cargo dep, so this read-only
// extension can wrap an FSBlockDeviceResource as an FsCoreDevice and slice
// a partition out of it before mounting. XFS is read-only and the crate
// doesn't pull in the am-img-* container readers, so unlike the ext4/ntfs
// extensions there are no qcow2/vhd/vhdx/vmdk headers here.
#import "fs_core.h"

#endif
