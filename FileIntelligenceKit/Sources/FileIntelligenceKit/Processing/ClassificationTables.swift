import Foundation

/// Deterministic lookup tables used by `ClassificationEngine`.
enum ClassificationTables {
    struct TypeEntry {
        let slug: String
        let label: String
        let confidence: Double

        init(_ slug: String, _ label: String, confidence: Double = 0.9) {
            self.slug = slug
            self.label = label
            self.confidence = confidence
        }
    }

    /// Extensions whose category is clearer from the extension than from the system type tree.
    static let extensions: [String: TypeEntry] = {
        var map: [String: TypeEntry] = [:]
        func add(_ slug: String, _ label: String, _ exts: [String], confidence: Double = 0.9) {
            for ext in exts { map[ext] = TypeEntry(slug, label, confidence: confidence) }
        }
        add("documents", "document", ["pdf", "doc", "docx", "pages", "rtf", "rtfd", "odt", "txt", "text", "md", "markdown", "tex", "epub", "mobi", "djvu", "wpd"])
        add("spreadsheets", "spreadsheet", ["xls", "xlsx", "xlsm", "numbers", "ods"])
        add("presentations", "presentation", ["ppt", "pptx", "key", "odp"])
        add("images", "image", ["jpg", "jpeg", "png", "gif", "heic", "heif", "tif", "tiff", "bmp", "webp", "svg", "raw", "cr2", "cr3", "nef", "arw", "dng", "ico", "icns"])
        add("video", "video", ["mov", "mp4", "m4v", "avi", "mkv", "webm", "wmv", "flv", "mpg", "mpeg", "3gp"])
        add("audio", "audio", ["mp3", "m4a", "aac", "wav", "aiff", "aif", "flac", "ogg", "opus", "wma", "alac", "mid", "midi"])
        add("archives", "archive", ["zip", "tar", "gz", "tgz", "bz2", "tbz", "xz", "txz", "7z", "rar", "zst", "lz", "lzma", "cab", "sit", "sitx"])
        add("archives", "disk image", ["iso", "img", "sparseimage", "sparsebundle", "toast"], confidence: 0.8)
        add("installers", "installer", ["dmg", "pkg", "mpkg"], confidence: 0.85)
        add("installers", "installer for another platform", ["msi", "deb", "rpm", "apk", "appimage", "xapk"], confidence: 0.85)
        add("applications", "executable", ["exe", "jar"], confidence: 0.6)
        add("design-assets", "design file", ["psd", "psb", "ai", "sketch", "fig", "xd", "afdesign", "afphoto", "afpub", "indd", "idml", "eps", "cdr", "procreate", "pxd", "pxm"])
        add("design-assets", "3D or media project", ["blend", "c4d", "max", "ma", "mb", "obj", "fbx", "stl", "usdz", "glb", "gltf", "aep", "prproj", "fcpbundle", "logicx", "band", "drp"], confidence: 0.85)
        add("databases", "database", ["sqlite", "sqlite3", "db", "db3", "realm", "mdb", "accdb", "fmp12", "frm", "ibd"], confidence: 0.85)
        add("datasets", "data file", ["csv", "tsv", "parquet", "jsonl", "ndjson", "arrow", "feather", "avro", "orc", "h5", "hdf5", "npy", "npz", "pkl", "pickle", "rds", "rdata", "sav", "dta", "mat", "geojson"], confidence: 0.85)
        add("fonts", "font", ["ttf", "otf", "woff", "woff2", "ttc", "dfont", "fnt", "pfb"])
        add("configuration", "configuration file", ["yaml", "yml", "toml", "ini", "cfg", "conf", "plist", "properties", "env", "editorconfig", "xcconfig", "entitlements"], confidence: 0.85)
        add("temporary", "temporary file", ["tmp", "temp", "crdownload", "part", "partial", "download", "opdownload", "swp", "swo", "lock", "bak", "old"], confidence: 0.9)
        for (ext, _) in sourceLanguages { map[ext] = TypeEntry("source-code", "source file", confidence: 0.9) }
        return map
    }()

    /// Extension to programming-language name.
    static let sourceLanguages: [String: String] = [
        "swift": "Swift", "m": "Objective-C", "mm": "Objective-C++", "h": "C/C++ Header", "hpp": "C++ Header",
        "c": "C", "cc": "C++", "cpp": "C++", "cxx": "C++", "cs": "C#", "java": "Java", "kt": "Kotlin",
        "kts": "Kotlin", "scala": "Scala", "go": "Go", "rs": "Rust", "py": "Python", "ipynb": "Jupyter Notebook",
        "rb": "Ruby", "php": "PHP", "js": "JavaScript", "mjs": "JavaScript", "cjs": "JavaScript",
        "jsx": "JavaScript (JSX)", "ts": "TypeScript", "tsx": "TypeScript (TSX)", "vue": "Vue", "svelte": "Svelte",
        "html": "HTML", "htm": "HTML", "css": "CSS", "scss": "SCSS", "sass": "Sass", "less": "Less",
        "sh": "Shell", "bash": "Shell", "zsh": "Shell", "fish": "Shell", "ps1": "PowerShell", "bat": "Batch",
        "lua": "Lua", "pl": "Perl", "r": "R", "jl": "Julia", "dart": "Dart", "ex": "Elixir", "exs": "Elixir",
        "erl": "Erlang", "hs": "Haskell", "ml": "OCaml", "clj": "Clojure", "sql": "SQL", "graphql": "GraphQL",
        "proto": "Protocol Buffers", "zig": "Zig", "nim": "Nim", "v": "V", "asm": "Assembly", "s": "Assembly",
        "gradle": "Gradle", "cmake": "CMake", "make": "Makefile", "mk": "Makefile", "tf": "Terraform",
    ]

    /// Well-known filenames without a meaningful extension.
    static let filenames: [String: TypeEntry] = [
        "makefile": TypeEntry("source-code", "build script"),
        "dockerfile": TypeEntry("source-code", "container build file"),
        "rakefile": TypeEntry("source-code", "build script"),
        "gemfile": TypeEntry("configuration", "dependency manifest"),
        "podfile": TypeEntry("configuration", "dependency manifest"),
        "procfile": TypeEntry("configuration", "process manifest"),
        "brewfile": TypeEntry("configuration", "dependency manifest"),
        "package.json": TypeEntry("configuration", "package manifest"),
        "package.swift": TypeEntry("source-code", "package manifest"),
        "cargo.toml": TypeEntry("configuration", "package manifest"),
        ".gitignore": TypeEntry("configuration", "version-control settings"),
        ".gitattributes": TypeEntry("configuration", "version-control settings"),
        ".gitmodules": TypeEntry("configuration", "version-control settings"),
        ".editorconfig": TypeEntry("configuration", "editor settings"),
        ".env": TypeEntry("configuration", "environment settings"),
        ".npmrc": TypeEntry("configuration", "tool settings"),
        ".zshrc": TypeEntry("configuration", "shell settings"),
        ".bashrc": TypeEntry("configuration", "shell settings"),
        ".profile": TypeEntry("configuration", "shell settings"),
        "readme": TypeEntry("documents", "readme", confidence: 0.8),
        "license": TypeEntry("documents", "license text", confidence: 0.8),
        "changelog": TypeEntry("documents", "change log", confidence: 0.8),
    ]

    /// System type conformance rules, checked in order when the extension table has no entry.
    static let conformance: [(uti: String, entry: TypeEntry)] = [
        ("com.apple.application-bundle", TypeEntry("applications", "application bundle", confidence: 0.95)),
        ("public.image", TypeEntry("images", "image", confidence: 0.85)),
        ("public.movie", TypeEntry("video", "video", confidence: 0.85)),
        ("public.audio", TypeEntry("audio", "audio", confidence: 0.85)),
        ("public.archive", TypeEntry("archives", "archive", confidence: 0.85)),
        ("public.font", TypeEntry("fonts", "font", confidence: 0.85)),
        ("public.spreadsheet", TypeEntry("spreadsheets", "spreadsheet", confidence: 0.85)),
        ("public.presentation", TypeEntry("presentations", "presentation", confidence: 0.85)),
        ("public.source-code", TypeEntry("source-code", "source file", confidence: 0.85)),
        ("public.script", TypeEntry("source-code", "script", confidence: 0.8)),
        ("public.database", TypeEntry("databases", "database", confidence: 0.8)),
        ("public.unix-executable", TypeEntry("applications", "executable", confidence: 0.6)),
        ("com.adobe.pdf", TypeEntry("documents", "PDF document", confidence: 0.9)),
        ("public.composite-content", TypeEntry("documents", "document", confidence: 0.75)),
        ("public.text", TypeEntry("documents", "text", confidence: 0.6)),
    ]

    /// Category implied by the file's leading bytes, used when neither extension nor type identifies it.
    static let signatures: [FormatSignature: TypeEntry] = [
        .pdf: TypeEntry("documents", "PDF document", confidence: 0.8),
        .zip: TypeEntry("archives", "ZIP archive", confidence: 0.7),
        .gzip: TypeEntry("archives", "gzip archive", confidence: 0.75),
        .bzip2: TypeEntry("archives", "bzip2 archive", confidence: 0.75),
        .xz: TypeEntry("archives", "xz archive", confidence: 0.75),
        .sevenZip: TypeEntry("archives", "7-Zip archive", confidence: 0.75),
        .rar: TypeEntry("archives", "RAR archive", confidence: 0.75),
        .png: TypeEntry("images", "PNG image", confidence: 0.8),
        .jpeg: TypeEntry("images", "JPEG image", confidence: 0.8),
        .gif: TypeEntry("images", "GIF image", confidence: 0.8),
        .tiff: TypeEntry("images", "TIFF image", confidence: 0.75),
        .webp: TypeEntry("images", "WebP image", confidence: 0.8),
        .heif: TypeEntry("images", "HEIF image", confidence: 0.8),
        .psd: TypeEntry("design-assets", "Photoshop document", confidence: 0.8),
        .sqlite: TypeEntry("databases", "SQLite database", confidence: 0.8),
        .machO: TypeEntry("applications", "Mach-O executable", confidence: 0.6),
        .elf: TypeEntry("applications", "Linux executable", confidence: 0.6),
        .windowsExecutable: TypeEntry("applications", "Windows executable", confidence: 0.55),
        .xar: TypeEntry("installers", "installer package", confidence: 0.7),
        .mp4Family: TypeEntry("video", "MPEG-4/QuickTime media", confidence: 0.65),
        .wave: TypeEntry("audio", "WAVE audio", confidence: 0.8),
        .avi: TypeEntry("video", "AVI video", confidence: 0.8),
        .ogg: TypeEntry("audio", "Ogg media", confidence: 0.65),
        .flac: TypeEntry("audio", "FLAC audio", confidence: 0.8),
        .mp3: TypeEntry("audio", "MP3 audio", confidence: 0.7),
        .trueTypeFont: TypeEntry("fonts", "TrueType font", confidence: 0.7),
        .openTypeFont: TypeEntry("fonts", "OpenType font", confidence: 0.8),
        .woff: TypeEntry("fonts", "WOFF font", confidence: 0.8),
        .woff2: TypeEntry("fonts", "WOFF2 font", confidence: 0.8),
    ]

    /// Signatures that the content of a correctly named file must have.
    /// Only extensions with unambiguous signatures are listed, so mismatches are meaningful.
    static let expectedSignatures: [String: Set<FormatSignature>] = [
        "pdf": [.pdf],
        "png": [.png],
        "jpg": [.jpeg], "jpeg": [.jpeg],
        "gif": [.gif],
        "zip": [.zip], "docx": [.zip], "xlsx": [.zip], "pptx": [.zip], "epub": [.zip], "jar": [.zip],
        "odt": [.zip], "ods": [.zip], "odp": [.zip],
        "gz": [.gzip], "tgz": [.gzip],
        "7z": [.sevenZip],
        "rar": [.rar],
        "sqlite": [.sqlite], "sqlite3": [.sqlite],
        "pkg": [.xar],
        "flac": [.flac],
        "webp": [.webp],
    ]

    /// Filename patterns for temporary items, checked before type rules.
    static func temporaryReason(filename: String, fileExtension: String?) -> String? {
        let lower = filename.lowercased()
        if lower.hasPrefix("~$") { return "Office lock file (name starts with “~$”)." }
        if lower.hasPrefix(".~lock.") { return "LibreOffice lock file." }
        if lower.hasSuffix("~") { return "Editor backup copy (name ends with “~”)." }
        if lower.hasPrefix(".#") { return "Editor lock file." }
        if let fileExtension, let entry = extensions[fileExtension], entry.slug == "temporary" {
            switch fileExtension {
            case "crdownload", "part", "partial", "download", "opdownload":
                return "Partially downloaded file (.\(fileExtension))."
            default:
                return "Temporary file extension (.\(fileExtension))."
            }
        }
        return nil
    }

    /// Whole-word filename keywords that suggest a document's purpose. Only suggestions, stored as tags.
    static let semanticKeywords: [String: String] = [
        "invoice": "invoice-or-receipt", "invoices": "invoice-or-receipt", "receipt": "invoice-or-receipt",
        "receipts": "invoice-or-receipt", "bill": "invoice-or-receipt",
        "lecture": "lecture-notes", "lectures": "lecture-notes", "lec": "lecture-notes", "slides": "lecture-notes",
        "assignment": "assignment", "homework": "assignment", "hw": "assignment", "coursework": "assignment",
        "syllabus": "academic", "exam": "academic", "midterm": "academic", "quiz": "academic", "tutorial": "academic",
        "thesis": "research", "dissertation": "research", "paper": "research", "preprint": "research", "arxiv": "research",
        "certificate": "certificate", "certification": "certificate",
        "report": "report", "reports": "report",
        "contract": "legal", "agreement": "legal", "nda": "legal",
        "manual": "reference", "handbook": "reference", "guide": "reference",
        "spec": "project-documentation", "specification": "project-documentation", "readme": "project-documentation",
        "statement": "financial", "tax": "financial", "payslip": "financial",
    ]

    /// Splits a name into lowercase words on punctuation, digits boundaries and camelCase.
    static func words(in filename: String) -> [String] {
        let stem = (filename as NSString).deletingPathExtension
        var words: [String] = []
        var current = ""
        var previousWasLower = false
        for character in stem {
            if character.isLetter {
                if character.isUppercase && previousWasLower && !current.isEmpty {
                    words.append(current.lowercased())
                    current = ""
                }
                current.append(character)
                previousWasLower = character.isLowercase
            } else {
                if !current.isEmpty { words.append(current.lowercased()) }
                current = ""
                previousWasLower = false
            }
        }
        if !current.isEmpty { words.append(current.lowercased()) }
        return words
    }
}
