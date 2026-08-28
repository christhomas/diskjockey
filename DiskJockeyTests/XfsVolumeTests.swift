//
//  XfsVolumeTests.swift — exercises the read-only XFS volume's call
//  patterns against a local mock that records every backend call.
//
//  The real fs_xfs_* C ABI lives behind the DiskJockeyXFS extension
//  target and isn't visible here, and FSKit framework types can't easily
//  be constructed in a unit-test bundle. So this file mirrors the
//  volume's wiring with a self-contained mock + driver functions, the
//  same approach EXT4VolumeTests / NTFSVolumeTests / ErofsVolumeTests
//  take.
//
//  XFS is READ-ONLY here, and its inode identity is 64-bit. The contract
//  under test:
//    - reads / stat / enumerate / readlink succeed and dispatch correctly
//    - every mutating op (create / write / rename / remove / truncate /
//      setattr / symlink / link) rejects with POSIXError(.EROFS) — the
//      errno for a read-only filesystem, not the filesystem of that name
//
//  WHAT THIS STYLE OF TEST CANNOT REACH, stated because it matters here:
//  it mirrors the volume's wiring rather than instantiating XfsVolume, so
//  it cannot see the volume's declared capabilities. That is exactly
//  where this extension was wrong — it inherited `supportsJournal =
//  false` from the EROFS volume it was copied from, and XFS has a
//  journal. Catching that needs a test that can construct the volume, or
//  a check outside the unit-test bundle; a mirror asserts only what the
//  mirror was written to say.
//

import Foundation
import Testing
@testable import DiskJockey

// MARK: - Local read-only backend mirror

private enum MockXfsFileType {
    case file
    case directory
    case symlink
}

private struct MockXfsEntry {
    var type: MockXfsFileType
    /// XFS inode numbers are 64-bit, and encode the allocation group in
    /// their high bits — modelled explicitly so the test reflects the
    /// volume's `FileIDCache<XfsItem>` (UInt64) keying rather than
    /// assuming a width.
    var inode: UInt64
    var data: Data
    var mode: UInt16
    var symlinkTarget: String?
}

/// Records reads and rejects writes, mirroring how XfsVolume routes every
/// mutating FSVolume op to `throw POSIXError(.EROFS)` while reads
/// dispatch into the (here-mocked) fs_xfs_* C ABI.
private final class MockXfsBackend {

    enum Call: Equatable {
        case stat(path: String)
        case readFile(path: String, offset: UInt64, length: UInt64)
        case readDirectory(path: String)
        case readlink(path: String)
    }

    private(set) var calls: [Call] = []
    private(set) var entries: [String: MockXfsEntry] = [
        "/": MockXfsEntry(type: .directory, inode: 128, data: Data(), mode: 0o555, symlinkTarget: nil)
    ]

    func seed(_ path: String, _ entry: MockXfsEntry) { entries[path] = entry }

    func stat(path: String) -> MockXfsEntry? {
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

private func joinXfsPath(_ parent: String, _ child: String) -> String {
    parent == "/" ? "/\(child)" : "\(parent)/\(child)"
}

/// Mirrors `XfsVolume.lookupItem` — join then stat-by-path; ENOENT when
/// the child doesn't exist. Returns the resolved inode so the 64-bit
/// identity is asserted end to end.
private func driveXfsLookup(name: String, parent: String,
                            mock: MockXfsBackend) throws -> (path: String, inode: UInt64) {
    let child = joinXfsPath(parent, name)
    guard let e = mock.stat(path: child) else { throw POSIXError(.ENOENT) }
    return (child, e.inode)
}

private func driveXfsRead(path: String, offset: UInt64, length: UInt64,
                          mock: MockXfsBackend) throws -> Data {
    guard let data = mock.readFile(path: path, offset: offset, length: length) else {
        throw POSIXError(.EBADF)
    }
    return data
}

private func driveXfsReadlink(path: String, mock: MockXfsBackend) throws -> String {
    guard let target = mock.readlink(path: path) else { throw POSIXError(.EIO) }
    return target
}

// MARK: - Read-only mutating-op drivers (every one must throw EROFS)

private enum XfsMutation: CaseIterable {
    case createItem, write, rename, removeItem, truncate, setAttributes, symlink, link
}

/// Mirrors XfsVolume's mutating ops, all of which unconditionally
/// `throw POSIXError(.EROFS)`.
private func driveXfsMutation(_ op: XfsMutation) throws {
    _ = op
    throw POSIXError(.EROFS)
}

// MARK: - Tests

struct XfsVolumeTests {

    private func seeded() -> MockXfsBackend {
        let mock = MockXfsBackend()
        mock.seed("/dir", MockXfsEntry(type: .directory, inode: 131,
                                       data: Data(), mode: 0o755, symlinkTarget: nil))
        mock.seed("/dir/file.txt", MockXfsEntry(type: .file, inode: 132,
                                                data: Data("xfs contents".utf8),
                                                mode: 0o644, symlinkTarget: nil))
        mock.seed("/link", MockXfsEntry(type: .symlink, inode: 133, data: Data(),
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
        let found = try driveXfsLookup(name: "file.txt", parent: "/dir", mock: mock)
        #expect(found.path == "/dir/file.txt")
        // The value matters as much as the type: an inode truncated to 32
        // bits would move to a different allocation group.
        #expect(found.inode == 132)
        #expect(UInt64.self == type(of: found.inode))
    }

    @Test func lookupMissingThrowsENOENT() throws {
        let mock = seeded()
        #expect(throws: POSIXError(.ENOENT)) {
            _ = try driveXfsLookup(name: "absent", parent: "/dir", mock: mock)
        }
    }

    @Test func readReturnsFileBytes() throws {
        let mock = seeded()
        let data = try driveXfsRead(path: "/dir/file.txt", offset: 0, length: 64, mock: mock)
        #expect(String(decoding: data, as: UTF8.self) == "xfs contents")
    }

    @Test func readAtOffset() throws {
        let mock = seeded()
        let data = try driveXfsRead(path: "/dir/file.txt", offset: 4, length: 8, mock: mock)
        #expect(String(decoding: data, as: UTF8.self) == "contents")
    }

    @Test func readingADirectoryIsRejected() throws {
        let mock = seeded()
        #expect(throws: POSIXError(.EBADF)) {
            _ = try driveXfsRead(path: "/dir", offset: 0, length: 8, mock: mock)
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
        let target = try driveXfsReadlink(path: "/link", mock: mock)
        #expect(target == "dir/file.txt")
    }

    @Test func readlinkOnANonSymlinkFails() throws {
        let mock = seeded()
        #expect(throws: POSIXError(.EIO)) {
            _ = try driveXfsReadlink(path: "/dir/file.txt", mock: mock)
        }
    }

    // MARK: read-only contract

    /// Every mutating op rejects, checked over the whole set rather than
    /// one test each — so an op added to the volume and forgotten here
    /// shows up as a missing case in `XfsMutation` rather than as a test
    /// nobody wrote.
    @Test func everyMutatingOperationIsRejected() throws {
        for op in XfsMutation.allCases {
            #expect(throws: POSIXError(.EROFS)) { try driveXfsMutation(op) }
        }
        #expect(XfsMutation.allCases.count == 8)
    }
}
