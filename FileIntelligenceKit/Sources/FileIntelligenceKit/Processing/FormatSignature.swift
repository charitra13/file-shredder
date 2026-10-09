import Foundation

/// File formats recognised from their leading bytes. Detection reads at most a few hundred bytes
/// and never interprets or executes the content.
public enum FormatSignature: String, Codable, Sendable, CaseIterable {
    case pdf
    case zip
    case gzip
    case bzip2
    case xz
    case sevenZip
    case rar
    case png
    case jpeg
    case gif
    case tiff
    case webp
    case heif
    case psd
    case sqlite
    case machO
    case elf
    case windowsExecutable
    case xar
    case mp4Family
    case wave
    case avi
    case ogg
    case flac
    case mp3
    case trueTypeFont
    case openTypeFont
    case woff
    case woff2
    case plainText
    case binary

    public var displayName: String {
        switch self {
        case .pdf: return "PDF"
        case .zip: return "ZIP"
        case .gzip: return "gzip"
        case .bzip2: return "bzip2"
        case .xz: return "xz"
        case .sevenZip: return "7-Zip"
        case .rar: return "RAR"
        case .png: return "PNG image"
        case .jpeg: return "JPEG image"
        case .gif: return "GIF image"
        case .tiff: return "TIFF image"
        case .webp: return "WebP image"
        case .heif: return "HEIF image"
        case .psd: return "Photoshop document"
        case .sqlite: return "SQLite database"
        case .machO: return "Mach-O executable"
        case .elf: return "ELF executable"
        case .windowsExecutable: return "Windows executable"
        case .xar: return "XAR archive (installer package)"
        case .mp4Family: return "MPEG-4/QuickTime media"
        case .wave: return "WAVE audio"
        case .avi: return "AVI video"
        case .ogg: return "Ogg media"
        case .flac: return "FLAC audio"
        case .mp3: return "MP3 audio"
        case .trueTypeFont: return "TrueType font"
        case .openTypeFont: return "OpenType font"
        case .woff: return "WOFF font"
        case .woff2: return "WOFF2 font"
        case .plainText: return "plain text"
        case .binary: return "unrecognised binary data"
        }
    }

    /// A system type identifier implied by the signature, used only when the extension gave none.
    public var impliedTypeIdentifier: String? {
        switch self {
        case .pdf: return "com.adobe.pdf"
        case .zip: return "public.zip-archive"
        case .gzip: return "org.gnu.gnu-zip-archive"
        case .bzip2: return "public.bzip2-archive"
        case .png: return "public.png"
        case .jpeg: return "public.jpeg"
        case .gif: return "com.compuserve.gif"
        case .tiff: return "public.tiff"
        case .webp: return "org.webmproject.webp"
        case .heif: return "public.heic"
        case .psd: return "com.adobe.photoshop-image"
        case .mp4Family: return "public.mpeg-4"
        case .wave: return "com.microsoft.waveform-audio"
        case .avi: return "public.avi"
        case .mp3: return "public.mp3"
        case .trueTypeFont: return "public.truetype-ttf-font"
        case .openTypeFont: return "public.opentype-font"
        case .plainText: return "public.plain-text"
        default: return nil
        }
    }

    public static let headerLength = 512

    /// Reads the first bytes of a regular file and identifies its format.
    public static func detect(path: String) -> FormatSignature? {
        guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: headerLength), !data.isEmpty else { return nil }
        return detect([UInt8](data))
    }

    public static func detect(_ bytes: [UInt8]) -> FormatSignature? {
        guard !bytes.isEmpty else { return nil }

        func starts(with prefix: [UInt8], at offset: Int = 0) -> Bool {
            guard bytes.count >= offset + prefix.count else { return false }
            for (index, byte) in prefix.enumerated() where bytes[offset + index] != byte {
                return false
            }
            return true
        }
        func ascii(_ text: String, at offset: Int = 0) -> Bool {
            starts(with: Array(text.utf8), at: offset)
        }

        if ascii("%PDF-") { return .pdf }
        if starts(with: [0x50, 0x4B, 0x03, 0x04]) || starts(with: [0x50, 0x4B, 0x05, 0x06])
            || starts(with: [0x50, 0x4B, 0x07, 0x08]) { return .zip }
        if starts(with: [0x1F, 0x8B]) { return .gzip }
        if ascii("BZh") { return .bzip2 }
        if starts(with: [0xFD, 0x37, 0x7A, 0x58, 0x5A, 0x00]) { return .xz }
        if starts(with: [0x37, 0x7A, 0xBC, 0xAF, 0x27, 0x1C]) { return .sevenZip }
        if starts(with: [0x52, 0x61, 0x72, 0x21, 0x1A, 0x07]) { return .rar }
        if starts(with: [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]) { return .png }
        if starts(with: [0xFF, 0xD8, 0xFF]) { return .jpeg }
        if ascii("GIF87a") || ascii("GIF89a") { return .gif }
        if starts(with: [0x49, 0x49, 0x2A, 0x00]) || starts(with: [0x4D, 0x4D, 0x00, 0x2A]) { return .tiff }
        if ascii("RIFF") {
            if ascii("WEBP", at: 8) { return .webp }
            if ascii("WAVE", at: 8) { return .wave }
            if ascii("AVI ", at: 8) { return .avi }
        }
        if ascii("ftyp", at: 4) {
            for brand in ["heic", "heix", "hevc", "mif1", "msf1", "avif"] where ascii(brand, at: 8) {
                return .heif
            }
            return .mp4Family
        }
        if ascii("8BPS") { return .psd }
        if ascii("SQLite format 3") && starts(with: [0x00], at: 15) { return .sqlite }
        if starts(with: [0xCF, 0xFA, 0xED, 0xFE]) || starts(with: [0xCE, 0xFA, 0xED, 0xFE])
            || starts(with: [0xFE, 0xED, 0xFA, 0xCF]) || starts(with: [0xFE, 0xED, 0xFA, 0xCE])
            || starts(with: [0xCA, 0xFE, 0xBA, 0xBE]) { return .machO }
        if starts(with: [0x7F, 0x45, 0x4C, 0x46]) { return .elf }
        if ascii("MZ") { return .windowsExecutable }
        if ascii("xar!") { return .xar }
        if ascii("OggS") { return .ogg }
        if ascii("fLaC") { return .flac }
        if ascii("ID3") || starts(with: [0xFF, 0xFB]) || starts(with: [0xFF, 0xF3]) { return .mp3 }
        if starts(with: [0x00, 0x01, 0x00, 0x00, 0x00]) { return .trueTypeFont }
        if ascii("OTTO") { return .openTypeFont }
        if ascii("wOFF") { return .woff }
        if ascii("wOF2") { return .woff2 }
        return looksLikeText(bytes) ? .plainText : .binary
    }

    /// Text if there are no NUL bytes and the sample is valid UTF-8 (allowing a truncated final character).
    static func looksLikeText(_ bytes: [UInt8]) -> Bool {
        if bytes.contains(0) { return false }
        for trim in 0...min(3, bytes.count - 1) {
            if String(bytes: bytes.dropLast(trim), encoding: .utf8) != nil {
                return true
            }
        }
        return false
    }
}
