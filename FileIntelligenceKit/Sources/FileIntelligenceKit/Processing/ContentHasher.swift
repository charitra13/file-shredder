import CryptoKit
import Foundation

/// Streams file contents through SHA-256 in bounded chunks. Never loads a whole file into memory.
public struct ContentHasher: Sendable {
    public var chunkSize: Int
    public var quickSampleSize: Int

    public init(chunkSize: Int = 1 << 20, quickSampleSize: Int = 64 * 1_024) {
        self.chunkSize = chunkSize
        self.quickSampleSize = quickSampleSize
    }

    /// Full-content SHA-256, hex encoded. Checks for task cancellation between chunks.
    public func sha256(path: String) throws -> String {
        guard let handle = FileHandle(forReadingAtPath: path) else {
            throw CocoaError(.fileReadNoPermission, userInfo: [NSFilePathErrorKey: path])
        }
        defer { try? handle.close() }
        var hasher = SHA256()
        while true {
            try Task.checkCancellation()
            guard let chunk = try handle.read(upToCount: chunkSize), !chunk.isEmpty else { break }
            hasher.update(data: chunk)
        }
        return Self.hex(hasher.finalize())
    }

    /// SHA-256 of the size, the first and the last `quickSampleSize` bytes.
    ///
    /// Equal quick hashes do not prove equality; they only select candidates for a full hash.
    public func quickHash(path: String, size: Int64) throws -> String {
        guard let handle = FileHandle(forReadingAtPath: path) else {
            throw CocoaError(.fileReadNoPermission, userInfo: [NSFilePathErrorKey: path])
        }
        defer { try? handle.close() }
        var hasher = SHA256()
        withUnsafeBytes(of: size.littleEndian) { hasher.update(bufferPointer: $0) }
        if let head = try handle.read(upToCount: quickSampleSize) {
            hasher.update(data: head)
        }
        if size > Int64(quickSampleSize * 2) {
            try handle.seek(toOffset: UInt64(size - Int64(quickSampleSize)))
            if let tail = try handle.read(upToCount: quickSampleSize) {
                hasher.update(data: tail)
            }
        }
        return Self.hex(hasher.finalize())
    }

    static func hex(_ digest: SHA256.Digest) -> String {
        digest.map { String(format: "%02x", $0) }.joined()
    }
}
