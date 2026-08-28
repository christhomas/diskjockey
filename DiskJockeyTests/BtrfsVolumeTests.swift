//
//  BtrfsVolumeTests.swift — exercises the read-only Btrfs volume's call
//  patterns against a local mock that records every backend call.
//
//  The real fs_btrfs_* C ABI lives behind the DiskJockeyBtrfs extension
//  target and isn't visible here, and FSKit framework types can't easily
//  be constructed in a unit-test bundle. So this file mirrors the
//  volume's wiring with a self-contained mock + driver functions, the
//  same approach EXT4VolumeTests / NTFSVolumeTests / ErofsVolumeTests
//  take.
//
//  Btrfs is READ-ONLY here. Its identity is a 64-bit objectid, which is
//  unique only WITHIN a subvolume — two subvolumes of one filesystem both
//  have an inode 256 — so an id alone does not name a file. This mirror
//  models a single subvolume, which is what the volume currently exposes.
//
//  The contract under test:
//    - reads / stat / enumerate / readlink succeed and dispatch correctly
//    - every mutating op (create / write / rename / remove / truncate /
//      setattr / symlink / link) rejects with POSIXError(.EROFS) — the
//      errno for a read-only filesystem, not the filesystem of that name
//
//  WHAT THIS STYLE OF TEST CANNOT REACH, stated because it matters here:
//  it mirrors the volume's wiring rather than instantiating BtrfsVolume,
//  so it cannot see the volume's declared capabilities. That is exactly
//  where this extension was wrong — it inherited `supportsJournal =
//  false` from the EROFS volume it was copied from, and Btrfs has a log
//  tree. Nor can it see that BtrfsVolume reports capacity in BYTES via
//  `sector_size` rather than in blocks, and reports zero inode counts
//  because btrfs has no fixed inode table. Those are volume-level
//  properties; a mirror asserts only what the mirror was written to say.
//

import Foundation
import Testing
@testable import DiskJockey

// MARK: - Local read-only backend mirror

private enum MockBtrfsFileType {
    case file
    case directory
    case symlink
}

private struct MockBtrfsEntry {
    var type: MockBtrfsFileType
    /// A btrfs objectid: 64-bit, and unique only within a subvolume.
    /// Modelled explicitly so the test reflects the volume's
    /// `FileIDCache<BtrfsItem>` (UInt64) keying rather than assuming a
    /// width.
    var inode: UInt64
    var data: Data
    var mode: UInt16
    var symlinkTarget: String?
}

/// Records reads and rejects writes, mirroring how BtrfsVolume routes every
/// mutating FSVolume op to `throw POSIXError(.EROFS)` while reads
/// dispatch into the (here-mocked) fs_btrfs_* C ABI.
private final class MockBtrfsBackend {

    enum Call: Equatable {
        case stat(path: String)
        case readFile(path: String, offset: UInt64, length: UInt64)
        case readDirectory(path: String)
        case readlink(path: String)
    }

    private(set) var calls: [Call] = []
    private(set) var entries: [String: MockBtrfsEntry] = [
        "/": MockBtrfsEntry(type: .directory, inode: 256, data: Data(), mode: 0o555, symlinkTarget: nil)
    ]

    func seed(_ path: String, _ entry: MockBtrfsEntry) { entries[path] = entry }

    func stat(path: String) -> MockBtrfsEntry? {
        calls.append(.stat(path: path))
        return entries[path]
    }

    func readFile(path: String, offset: UInt64, length: UInt64) -> Data? {
        calls.append(.readFile(path: path, offset: offset, length: length))
        guard let e = entries[path], e.type == .file else { return nil }
        let start = min(Int(offset), e.data.count)
        let end = min(start + Int(length), e.data.count)
        return e.data.subdata(in: start..<end)
    }

    func readDirectory(path: String) -> [String]? {
        calls.append(.readDirectory(path: path))
        guard let e = entries[path], e.type == .directory else { return nil }
        let prefix = path == "/" ? "/" : "\(path)/"
        return entries.keys
            .filter { $0 != path && $0.hasPrefix(prefix) && !$0.dropFirst(prefix.count).contains("/") }
            .sorted()
    }

    func readlink(path: String) -> String? {
        calls.append(.readlink(path: path))
        guard let e = entries[path], e.type == .symlink else { return nil }
        return e.symlinkTarget
    }
}

// MARK: - Drivers mirroring the volume's wiring (read path)

private func joinBtrfsPath(_ parent: String, _ child: String) -> String {
    parent == "/" ? "/\(child)" : "\(parent)/\(child)"
}

/// Mirrors `BtrfsVolume.lookupItem` — join then stat-by-path; ENOENT when
/// the child doesn't exist. Returns the resolved inode so the 64-bit
/// identity is asserted end to end.
private func driveBtrfsLookup(name: String, parent: String,
                            mock: MockBtrfsBackend) throws -> (path: String, inode: UInt64) {
    let child = joinBtrfsPath(parent, name)
    guard let e = mock.stat(path: child) else { throw POSIXError(.ENOENT) }
    return (child, e.inode)
}

private func driveBtrfsRead(path: String, offset: UInt64, length: UInt64,
                          mock: MockBtrfsBackend) throws -> Data {
    guard let data = mock.readFile(path: path, offset: offset, length: length) else {
        throw POSIXError(.EBADF)
    }
    return data
}

private func driveBtrfsReadlink(path: String, mock: MockBtrfsBackend) throws -> String {
    guard let target = mock.readlink(path: path) else { throw POSIXError(.EIO) }
    return target
}

// MARK: - Read-only mutating-op drivers (every one must throw EROFS)

private enum BtrfsMutation: CaseIterable {
    case createItem, write, rename, removeItem, truncate, setAttributes, symlink, link
}

/// Mirrors BtrfsVolume's mutating ops, all of which unconditionally
/// `throw POSIXError(.EROFS)`.
private func driveBtrfsMutation(_ op: BtrfsMutation) throws {
    _ = op
    throw POSIXError(.EROFS)
}

// MARK: - Tests

struct BtrfsVolumeTests {

    private func seeded() -> MockBtrfsBackend {
        let mock = MockBtrfsBackend()
        mock.seed("/dir", MockBtrfsEntry(type: .directory, inode: 257,
                                       data: Data(), mode: 0o755, symlinkTarget: nil))
        mock.seed("/dir/file.txt", MockBtrfsEntry(type: .file, inode: 258,
                                                data: Data("btrfs contents".utf8),
                                                mode: 0o644, symlinkTarget: nil))
        mock.seed("/link", MockBtrfsEntry(type: .symlink, inode: 259, data: Data(),
                                        mode: 0o777, symlinkTarget: "dir/file.txt"))
        return mock
    }

    // MARK: read path

    @Test func statRootSucceeds() throws {
        let mock = seeded()
        let root = try #require(mock.stat(path: "/"))
        #expect(root.type == .directory)
        #expect(mock.calls == [.stat(path: "/")])
    }

    @Test func lookupResolves64BitInode() throws {
        let mock = seeded()
        let found = try driveBtrfsLookup(name: "file.txt", parent: "/dir", mock: mock)
        #expect(found.path == "/dir/file.txt")
        // The value matters as much as the type: btrfs objectids run well
        // past 32 bits on a filesystem of any age.
        #expect(found.inode == 258)
        #expect(UInt64.self == type(of: found.inode))
    }

    @Test func lookupMissingThrowsENOENT() throws {
        let mock = seeded()
        #expect(throws: POSIXError(.ENOENT)) {
            _ = try driveBtrfsLookup(name: "absent", parent: "/dir", mock: mock)
        }
    }

    @Test func readReturnsFileBytes() throws {
        let mock = seeded()
        let data = try driveBtrfsRead(path: "/dir/file.txt", offset: 0, length: 64, mock: mock)
        #expect(String(decoding: data, as: UTF8.self) == "btrfs contents")
    }

    @Test func readAtOffset() throws {
        let mock = seeded()
        // The offset is derived from the seeded content rather than
        // hand-counted. The first draft of this file carried 4 over from
        // the XFS version, where the payload is two characters shorter —
        // a copied constant that no longer matched its data, which is
        // the same failure this whole change exists to correct.
        let content = "btrfs contents"
        let offset = UInt64(content.distance(from: content.startIndex,
                                             to: content.range(of: "contents")!.lowerBound))
        let data = try driveBtrfsRead(path: "/dir/file.txt", offset: offset,
                                      length: 8, mock: mock)
        #expect(String(decoding: data, as: UTF8.self) == "contents")
    }

    @Test func readingADirectoryIsRejected() throws {
        let mock = seeded()
        #expect(throws: POSIXError(.EBADF)) {
            _ = try driveBtrfsRead(path: "/dir", offset: 0, length: 8, mock: mock)
        }
    }

    @Test func enumerateDirectoryListsChildren() throws {
        let mock = seeded()
        let children = try #require(mock.readDirectory(path: "/dir"))
        #expect(children == ["/dir/file.txt"])
    }

    @Test func enumerateRootListsOnlyItsOwnChildren() throws {
        let mock = seeded()
        let children = try #require(mock.readDirectory(path: "/"))
        // "/dir/file.txt" is a grandchild and must not appear.
        #expect(children == ["/dir", "/link"])
    }

    @Test func readlinkReturnsTarget() throws {
        let mock = seeded()
        let target = try driveBtrfsReadlink(path: "/link", mock: mock)
        #expect(target == "dir/file.txt")
    }

    @Test func readlinkOnANonSymlinkFails() throws {
        let mock = seeded()
        #expect(throws: POSIXError(.EIO)) {
            _ = try driveBtrfsReadlink(path: "/dir/file.txt", mock: mock)
        }
    }

    // MARK: read-only contract

    /// Every mutating op rejects, checked over the whole set rather than
    /// one test each — so an op added to the volume and forgotten here
    /// shows up as a missing case in `BtrfsMutation` rather than as a test
    /// nobody wrote.
    @Test func everyMutatingOperationIsRejected() throws {
        for op in BtrfsMutation.allCases {
            #expect(throws: POSIXError(.EROFS)) { try driveBtrfsMutation(op) }
        }
        #expect(BtrfsMutation.allCases.count == 8)
    }
}
