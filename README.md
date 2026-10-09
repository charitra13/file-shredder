# File Intelligence

A native macOS app (SwiftUI, macOS 14+) that builds a private, searchable index of the folders and drives you choose. It identifies what your files are, finds exact duplicates and large files, and explains which files may be worth reviewing. Everything runs locally. There is no account, no backend and no network access, and the app never deletes files.

> **Status:** Phases 1–3 of the plan (foundation, index reliability, classification and storage intelligence) are implemented. The code was written in an environment without a Swift toolchain, so the first build and test run happen on a Mac or in CI. See [Build status](#build-status).

## Features in this version

| Area | What works |
| --- | --- |
| Indexed locations | Add several folders or drives with the native folder picker. Access is persisted with security-scoped bookmarks (App Sandbox). You can pause, resume, rescan, cancel and remove locations. Overlapping locations never create duplicate records. Protected system folders are refused. |
| Universal index | Every accessible item is recorded: regular files (including unknown types and files without an extension), folders, symbolic links (recorded, never followed), packages such as `.app` bundles (one item with an estimated size) and special files. |
| Reliable rescans | Incremental rescans, rename and move reconciliation by inode and creation date (decisions follow the file), hard-link awareness, and missing-file detection that runs only after a complete pass. Unreadable folders are marked *Not Readable*, newly excluded items leave the index, and a disconnected drive is marked *Location Unavailable* instead of deleted. Interrupted scans are recovered at launch, and FSEvents change watching runs alongside periodic reconciliation. |
| Metadata | Uniform Type Identifiers, content signatures from the first 512 bytes (PDF, ZIP, images, SQLite, Mach-O, fonts, media and more), image dimensions (ImageIO), audio and video duration, size and codec (AVFoundation, with a timeout), and PDF page counts (PDFKit). |
| Classification | Deterministic, offline, layered rules: your rules, then links, packages, temporary patterns, the extension table, system type conformance, well-known filenames and content signatures. Mismatched extensions are classified by content. Low-confidence results go to *Unknown*. Every result stores its category, source, confidence and rationale. Filename keywords add suggested tags but never assign a category on their own. Your corrections are never overwritten, and three consistent corrections for an extension become a transparent learned rule that you can reset. |
| Duplicates | Exact duplicates only: candidates by size, then a quick hash of head and tail for large files, then a full SHA-256. Each file is re-checked on disk before and after hashing. Savings are computed without double-counting hard links. You choose the copy to keep, and *Verify Again* re-reads every copy. |
| Review priority | An explainable 0–100 heuristic built from duplicates, temporary files, old installers, large files and archives, archives that look already extracted, unclassified items and staleness. It is lowered for files inside project folders and for code, configuration and databases. Keep and Ignore suppress suggestions. Weights and thresholds are configurable. |
| UI | Overview, All Files (sortable, filterable, paginated table with an inspector), Categories, Duplicates, Large Files, Review Candidates, Indexed Locations, Activity (scans, problems, your decisions) and Settings (indexing, scoring, category rules, maintenance, privacy). Supports light and dark mode, keyboard shortcuts (⌘1–⌘9, ⇧⌘O, ⇧⌘R) and context menus. |

Not in this version (planned for later phases): content extraction and full-text search (FTS5), the archive and Move to Trash workflows, notifications, and optional local semantic intelligence. The schema already has the `extracted_content` table and the `content_*` status columns.

## Repository layout

```
project.yml                       XcodeGen spec for the macOS app target (sandbox, entitlements)
App/FileIntelligence/             SwiftUI app: AppModel, sidebar, feature views
FileIntelligenceKit/              Swift package with all non-UI logic
  Sources/FileIntelligenceKit/
    Core/                         Models, errors, utilities (paths, lstat, dates, SQL helpers)
    Database/                     AppDatabase, versioned migrations, repositories
    FileSystem/                   Root registry, bookmarks, scanner, exclusions, FSEvents monitor
    Processing/                   Signatures, metadata, classification, hashing, duplicates, scoring
    Indexing/                     IndexWriter (reconciliation), IndexingService, ProcessingPipeline
    Services/                     Review decisions, maintenance
    IndexEnvironment.swift        Composition root shared by the app and tests
  Tests/FileIntelligenceKitTests/ XCTest suites using temporary fixtures only
docs/ARCHITECTURE.md              Design decisions and known limitations
```

## Building

Requirements: macOS 14 or later, Xcode 15.4 or later (Xcode 16 recommended) and [XcodeGen](https://github.com/yonaskolb/XcodeGen).

```sh
brew install xcodegen
xcodegen generate
open FileIntelligence.xcodeproj
```

Choose the **FileIntelligence** scheme and run. Signing defaults to "Sign to Run Locally". To distribute the app, set your team in the target's Signing & Capabilities.

### Running the tests

The core logic lives in the Swift package and is tested with XCTest:

```sh
cd FileIntelligenceKit
swift test
```

The tests create their fixtures in fresh temporary folders and their own databases. They never read or modify personal files.

## Build status

This code was written in a Linux container with no Swift compiler, and network policy blocked downloading one, so **neither the app nor the tests have been compiled or run yet**. The CI workflow (`.github/workflows/ci.yml`) runs `swift test` and an unsigned `xcodebuild` on a GitHub-hosted macOS runner, and that is where the first real results come from. Expect some compile fixes in the first round.

## Privacy

- The index (`index.sqlite`) is stored in the app's sandbox container under Application Support.
- Nothing is uploaded: there are no network calls, no telemetry and no external AI.
- The app reads only the locations you add. Removing a location removes it from the index and leaves your files untouched.
- Files are never executed. Signatures are read from the first 512 bytes, and media metadata comes from Apple's parsers. *Open* is disabled for applications, installers and scripts.
