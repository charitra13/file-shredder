import Darwin
import Foundation

public struct FileStatReadError: Error, Sendable, Equatable {
    public let code: Int32

    public init(code: Int32) { self.code = code }
}

/// The subset of `lstat(2)` results the indexer relies on. Symbolic links are never followed.
public struct FileStat: Sendable, Equatable {
    public enum Kind: Sendable, Equatable {
        case regular
        case directory
        case symlink
        case other
    }

    public var kind: Kind
    public var size: Int64
    public var allocatedSize: Int64
    public var inode: UInt64
    public var device: Int32
    public var modifiedAt: Date
    public var createdAt: Date?
    /// The `UF_HIDDEN` flag (set by `chflags hidden`).
    public var hasHiddenFlag: Bool

    /// The inode stored in SQLite, which has no unsigned 64-bit type.
    public var storedInode: Int64 { Int64(bitPattern: inode) }

    /// Reads metadata for `path` without following a final symbolic link.
    public static func read(_ path: String) -> Result<FileStat, FileStatReadError> {
        var info = stat()
        guard Darwin.lstat(path, &info) == 0 else {
            return .failure(FileStatReadError(code: errno))
        }

        let kind: Kind
        switch UInt32(info.st_mode) & 0o170000 {
        case 0o100000: kind = .regular
        case 0o040000: kind = .directory
        case 0o120000: kind = .symlink
        default: kind = .other
        }

        let birth = info.st_birthtimespec
        let createdAt: Date? = birth.tv_sec > 0 ? Self.date(from: birth) : nil

        return .success(FileStat(
            kind: kind,
            size: Int64(info.st_size),
            allocatedSize: Int64(info.st_blocks) * 512,
            inode: UInt64(info.st_ino),
            device: Int32(info.st_dev),
            modifiedAt: Self.date(from: info.st_mtimespec),
            createdAt: createdAt,
            hasHiddenFlag: (UInt32(info.st_flags) & 0x8000) != 0
        ))
    }

    private static func date(from spec: timespec) -> Date {
        let seconds = TimeInterval(spec.tv_sec) + TimeInterval(spec.tv_nsec) / 1_000_000_000
        return DateUtilities.truncatedToMilliseconds(Date(timeIntervalSince1970: seconds))
    }
}
