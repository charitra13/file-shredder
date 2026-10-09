# Architecture

## Module boundaries

The app is split into a SwiftUI target and one Swift package, `FileIntelligenceKit`, which contains all non-UI logic. The package is organised by responsibility:

```
Core ─────────────┐  models, errors, utilities (no I/O policy)
Database ─────────┤  AppDatabase (GRDB DatabasePool, WAL), migrations, read repositories
FileSystem ───────┤  RootRegistry, BookmarkManaging, FileScanner, ExclusionPolicy, FileMonitor
Processing ───────┤  FormatSignature, MetadataEnricher, ClassificationEngine/Service,
                  │  ContentHasher, DuplicateDetector, CleanupScorer
Indexing ─────────┤  IndexWriter (reconciliation), IndexingService (actor), ProcessingPipeline
Services ─────────┘  ReviewService (decisions), MaintenanceService
IndexEnvironment     composition root used by the app and by tests
```

The app layer (`AppModel`, an `@Observable` main-actor class) holds view state and calls services. Views contain no business logic beyond composing a `FileQuery`.

A single package module (rather than one module per folder) keeps the public surface explicit while avoiding a large amount of cross-module boilerplate. The folders, protocols (`BookmarkManaging`) and injected value types (`TypeConformance`, `ContentHasher`, `FileScanner`) keep the boundaries testable.

## Pipeline

1. **Discovery and metadata** (`FileScanner`): an iterative walk using `contentsOfDirectory` and `lstat`. Nothing is opened. Observations are emitted in batches of 500.
2. **Index writes** (`IndexWriter.apply`): one transaction per batch, with an upsert by path and move detection.
3. **Finalisation** (`IndexWriter.finalize`): runs only after a complete pass and reconciles items that were not seen.
4. **Processing** (`ProcessingPipeline`, coalesced and incremental): enrichment (signatures, media metadata) → classification → duplicate hashing → scoring.

Metadata is always persisted before any content work, so the index is usable immediately and a slow or failing file cannot block it.

Concurrency: `IndexingService` is an actor. It allows one scan per location and scans locations one after another to bound disk I/O. Processing passes are coalesced: a request during a pass schedules one more pass. Hashing and media reads use bounded task groups (2 and 4 tasks). GRDB's `DatabasePool` lets the UI read while indexing writes.

## Identity and reconciliation

- `files.path` is unique. The stable internal `id` carries user decisions, tags, actions and relationships.
- **Moves and renames**: a new path whose `(volume_uuid, inode, item_kind)` matches an existing record, with an equal creation date, takes over that record, provided the old path no longer holds that inode. If the old path still holds it, the match is a hard link and gets its own record. A creation-date mismatch means the inode was reused. Folder moves carry their contents because every descendant matches by inode.
- The volume identity comes from the volume UUID, falling back to the device number, which is not stable across remounts.
- **Missing detection** runs only after a complete pass of the scan's scope. Each unseen record is checked on disk: `ENOENT` means missing, a permission error means not readable, and an item that still exists is out of scope (newly excluded) and leaves the index. Records are never deleted just because a scan could not see them.
- **Disconnected locations**: if a location's folder is unreachable, its items become `unavailable` and the scan stops. Reconnecting restores them.
- **Interrupted scans**: runs left in `running` are marked `interrupted` at launch. The next scan is a full incremental pass in which unchanged items cost one `lstat` and an indexed lookup. There is no mid-tree resume. This is deliberate, because missing detection needs a full pass and a partial resume could mis-mark files.

## Overlapping locations

Each item belongs to exactly one location: the deepest *enabled* location that contains it. A scan records the folder entry of a nested location but does not descend into it, and each scan reconciles only the items it owns. Adding, enabling, disabling or removing a location transfers ownership in a single transaction, so review decisions survive.

## Symbolic links, packages and cycles

- Symbolic links are recorded as links with their target and never followed, so link cycles cannot occur. Folders are also tracked by `(device, inode)` as a guard against aliasing.
- Packages (`.app`, `.photoslibrary`, and so on) are recorded as one item. Their size is estimated by summing regular files, capped at 25,000 entries (`size_is_estimate` marks a capped value).
- *Opaque* folders (default: `.git`, `.svn`, `.hg`) are recorded with an estimated size but not descended into. *Excluded* folders (Trash, Spotlight and similar) are skipped entirely. Both lists are configurable.

## Classification

`ClassificationEngine` is a pure function of filename, extension, UTI, item kind, size and content signature. Rules apply in a fixed order and each result stores its source, confidence and rationale. Results below 0.5 confidence are recorded as Unknown, with the tentative match in the rationale. Filename keywords (whole words, including camelCase splits) produce *suggested* tags only. No sensitive category is ever assigned from weak evidence.

Personalisation: user classifications (`classification_source = 'user'`) are never touched by automatic passes. When at least three user corrections share an extension and agree, a `learned` rule is written to `category_rules`. It is visible in Settings and removed by *Reset Learned Preferences*. Conflicting corrections delete the learned rule.

## Duplicates and scoring

Duplicates are exact only (SHA-256), and similarity is never reported as duplication. `duplicate_groups` is a materialised view, rebuilt after hashing, that keeps the user's preferred copy. Reclaimable bytes are `(distinct inodes − 1) × size`. APFS clones also share blocks, but there is no public API to detect them cheaply, so savings can be overstated for cloned files.

The cleanup score is `clamp(Σ weights, 0, 100)` over named signals, and it is stored with its reasons. It is a review-ordering heuristic: it never triggers an operation, and Keep or Ignore set it to 0. Penalties apply only when a positive signal exists, so a stale file alone stays below the candidate threshold. The default threshold is 25.

## Database

SQLite through GRDB 6, with versioned migrations (`Schema.swift`) and foreign keys enabled. Dates are stored in UTC by GRDB and displayed in the user's locale. Hot paths use cached prepared statements. Subtree queries use `path >= 'dir/' AND path < 'dir0'`, which the unique `path` index serves (`LIKE` would not). Lists are paginated with `LIMIT`/`OFFSET` at 200 rows per page; keyset pagination is a future optimisation if very deep paging proves slow.

Tables: `scan_roots`, `files`, `categories` (seeded, hierarchical), `file_tags`, `file_metadata`, `extracted_content` (reserved for Phase 4), `scan_runs`, `scan_issues`, `duplicate_groups`, `file_relationships`, `file_actions`, `category_rules`, `user_preferences`.

## Security and privacy

- App Sandbox with user-selected read-write access and app-scoped security bookmarks. Access starts at launch for enabled locations.
- Protected locations (`/`, `/System`, `/Library`, `/private`, `/usr`, `~/Library`, and others) are refused.
- Nothing executes or interprets file contents beyond the first 512 bytes and Apple's metadata parsers. PDFs over 512 MB are not opened, and AVFoundation reads time out after 10 s.
- There is no networking code. Diagnostic messages contain paths but never file contents.

## Known limitations

- **Not yet compiled or tested** (see the README). The first CI run will show compile errors to fix.
- FSEvents monitoring runs only while the app is open. Reconciliation scans (default every 6 hours, and at launch for stale locations) cover the rest. There is no background agent.
- Inode-based move detection does not cross volumes, because a cross-volume move is a copy plus a delete. Such files appear as new items and the old record becomes missing.
- `withTimeout` cancels cooperative work only. A media parser that blocks without checking cancellation still holds one of the four enrichment slots until it returns.
- Packages and opaque folders above 25,000 entries report a capped (lower-bound) size.
- Phases 4–7 (content extraction and FTS5 search, Trash and Archive workflows, notifications, optional local intelligence) are not implemented.
