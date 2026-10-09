import Foundation

enum VolumeInfo {
    struct Description {
        var rootType: RootType
        var volumeUUID: String?
    }

    static func describe(_ url: URL) -> Description {
        let keys: Set<URLResourceKey> = [
            .volumeUUIDStringKey, .volumeIsRemovableKey, .volumeIsInternalKey, .volumeIsLocalKey,
        ]
        guard let values = try? url.resourceValues(forKeys: keys) else {
            return Description(rootType: .folder, volumeUUID: nil)
        }
        let type: RootType
        if values.volumeIsLocal == false {
            type = .networkVolume
        } else if values.volumeIsRemovable == true || values.volumeIsInternal == false {
            type = .externalVolume
        } else {
            type = .folder
        }
        return Description(rootType: type, volumeUUID: values.volumeUUIDString)
    }
}

/// Maps device numbers to volume UUIDs during a scan, so inode identities survive remounts.
final class VolumeIdentityResolver {
    private var cache: [Int32: String] = [:]

    func identity(device: Int32, samplePath: String) -> String {
        if let known = cache[device] {
            return known
        }
        let values = try? URL(fileURLWithPath: samplePath).resourceValues(forKeys: [.volumeUUIDStringKey])
        // Device numbers are not stable across remounts, so they are only a fallback.
        let identity = values?.volumeUUIDString ?? "device-\(device)"
        cache[device] = identity
        return identity
    }
}
