import Foundation
import GRDB

/// Versioned schema migrations. Never edit a registered migration; add a new one instead.
enum Schema {
    static var migrator: DatabaseMigrator {
        var migrator = DatabaseMigrator()
        migrator.registerMigration("v1_initial_schema") { db in
            try createInitialSchema(db)
            try seedCategories(db)
        }
        return migrator
    }

    // MARK: - v1

    private static func createInitialSchema(_ db: Database) throws {
        try db.create(table: "scan_roots") { t in
            t.autoIncrementedPrimaryKey("id")
            t.column("display_name", .text).notNull()
            t.column("path", .text).notNull().unique()
            t.column("bookmark", .blob)
            t.column("root_type", .text).notNull()
            t.column("volume_uuid", .text)
            t.column("is_enabled", .boolean).notNull().defaults(to: true)
            t.column("scan_state", .text).notNull().defaults(to: "idle")
            t.column("last_successful_scan_at", .datetime)
            t.column("last_scan_started_at", .datetime)
            t.column("exclusions", .text).notNull()
            t.column("last_error", .text)
            t.column("created_at", .datetime).notNull()
        }

        try db.create(table: "categories") { t in
            t.autoIncrementedPrimaryKey("id")
            t.column("slug", .text).notNull().unique()
            t.column("name", .text).notNull()
            t.column("parent_id", .integer).indexed().references("categories", onDelete: .setNull)
            t.column("description", .text)
            t.column("kind", .text).notNull()
            t.column("is_system", .boolean).notNull().defaults(to: false)
            t.column("sort_order", .integer).notNull().defaults(to: 0)
        }

        try db.create(table: "files") { t in
            t.autoIncrementedPrimaryKey("id")
            t.column("root_id", .integer).notNull().indexed().references("scan_roots", onDelete: .cascade)
            t.column("path", .text).notNull().unique()
            t.column("filename", .text).notNull()
            t.column("parent_path", .text).notNull().indexed()
            t.column("file_extension", .text)
            t.column("uti", .text)
            t.column("mime_type", .text)
            t.column("item_kind", .text).notNull()
            t.column("size_bytes", .integer).notNull().defaults(to: 0)
            t.column("allocated_bytes", .integer)
            t.column("size_is_estimate", .boolean).notNull().defaults(to: false)
            t.column("created_at", .datetime)
            t.column("modified_at", .datetime)
            t.column("volume_uuid", .text)
            t.column("inode", .integer)
            t.column("is_hidden", .boolean).notNull().defaults(to: false)
            t.column("symlink_target", .text)
            t.column("detected_signature", .text)
            t.column("quick_hash", .text)
            t.column("content_hash", .text).indexed()
            t.column("hashed_at", .datetime)
            t.column("category_id", .integer).indexed().references("categories", onDelete: .setNull)
            t.column("classification_source", .text).notNull().defaults(to: ClassificationSource.none.rawValue)
            t.column("classification_confidence", .double)
            t.column("classification_explanation", .text)
            t.column("classified_at", .datetime)
            t.column("enriched_at", .datetime)
            t.column("content_extraction_status", .text).notNull().defaults(to: ExtractionStatus.notAttempted.rawValue)
            t.column("content_index_status", .text).notNull().defaults(to: ContentIndexStatus.notIndexed.rawValue)
            t.column("review_status", .text).notNull().defaults(to: ReviewStatus.unreviewed.rawValue).indexed()
            t.column("reviewed_at", .datetime)
            t.column("cleanup_priority", .integer).indexed()
            t.column("cleanup_reasons", .text)
            t.column("scored_at", .datetime)
            t.column("first_indexed_at", .datetime).notNull()
            t.column("last_indexed_at", .datetime).notNull()
            t.column("last_seen_at", .datetime).notNull()
            t.column("last_seen_scan_id", .integer)
            t.column("availability", .text).notNull().defaults(to: Availability.available.rawValue).indexed()
            t.column("missing_since", .datetime)
        }
        try db.create(index: "files_on_volume_inode", on: "files", columns: ["volume_uuid", "inode"])
        try db.create(index: "files_on_size", on: "files", columns: ["size_bytes"])
        try db.create(index: "files_on_modified_at", on: "files", columns: ["modified_at"])
        try db.create(index: "files_on_filename", on: "files", columns: ["filename"])
        try db.create(index: "files_on_root_last_seen", on: "files", columns: ["root_id", "last_seen_scan_id"])

        try db.create(table: "file_tags") { t in
            t.column("file_id", .integer).notNull().references("files", onDelete: .cascade)
            t.column("tag", .text).notNull()
            t.column("source", .text).notNull()
            t.column("created_at", .datetime).notNull()
            t.primaryKey(["file_id", "tag"])
        }
        try db.create(index: "file_tags_on_tag", on: "file_tags", columns: ["tag"])

        try db.create(table: "file_metadata") { t in
            t.column("file_id", .integer).primaryKey().references("files", onDelete: .cascade)
            t.column("pixel_width", .integer)
            t.column("pixel_height", .integer)
            t.column("duration_seconds", .double)
            t.column("page_count", .integer)
            t.column("video_codec", .text)
            t.column("source_language", .text)
            t.column("extracted_at", .datetime).notNull()
            t.column("extraction_error", .text)
        }

        try db.create(table: "extracted_content") { t in
            t.column("file_id", .integer).primaryKey().references("files", onDelete: .cascade)
            t.column("text", .text).notNull()
            t.column("character_count", .integer).notNull()
            t.column("is_truncated", .boolean).notNull().defaults(to: false)
            t.column("extractor", .text).notNull()
            t.column("extracted_at", .datetime).notNull()
        }

        try db.create(table: "scan_runs") { t in
            t.autoIncrementedPrimaryKey("id")
            t.column("root_id", .integer).notNull().indexed().references("scan_roots", onDelete: .cascade)
            t.column("kind", .text).notNull()
            t.column("scope_path", .text).notNull()
            t.column("started_at", .datetime).notNull()
            t.column("finished_at", .datetime)
            t.column("state", .text).notNull()
            t.column("items_seen", .integer).notNull().defaults(to: 0)
            t.column("directories_visited", .integer).notNull().defaults(to: 0)
            t.column("files_added", .integer).notNull().defaults(to: 0)
            t.column("files_updated", .integer).notNull().defaults(to: 0)
            t.column("files_moved", .integer).notNull().defaults(to: 0)
            t.column("files_missing", .integer).notNull().defaults(to: 0)
            t.column("files_inaccessible", .integer).notNull().defaults(to: 0)
            t.column("files_removed_from_index", .integer).notNull().defaults(to: 0)
            t.column("issues_count", .integer).notNull().defaults(to: 0)
            t.column("last_error", .text)
        }

        try db.create(table: "scan_issues") { t in
            t.autoIncrementedPrimaryKey("id")
            t.column("scan_run_id", .integer).notNull().indexed().references("scan_runs", onDelete: .cascade)
            t.column("path", .text).notNull()
            t.column("message", .text).notNull()
            t.column("created_at", .datetime).notNull()
        }

        try db.create(table: "duplicate_groups") { t in
            t.autoIncrementedPrimaryKey("id")
            t.column("content_hash", .text).notNull().unique()
            t.column("size_bytes", .integer).notNull()
            t.column("file_count", .integer).notNull()
            t.column("distinct_item_count", .integer).notNull()
            t.column("reclaimable_bytes", .integer).notNull()
            t.column("preferred_file_id", .integer).references("files", onDelete: .setNull)
            t.column("reference_file_id", .integer).references("files", onDelete: .setNull)
            t.column("updated_at", .datetime).notNull()
        }
        try db.create(index: "duplicate_groups_on_reclaimable", on: "duplicate_groups", columns: ["reclaimable_bytes"])

        try db.create(table: "file_relationships") { t in
            t.autoIncrementedPrimaryKey("id")
            t.column("source_file_id", .integer).notNull().indexed().references("files", onDelete: .cascade)
            t.column("target_file_id", .integer).notNull().indexed().references("files", onDelete: .cascade)
            t.column("kind", .text).notNull()
            t.column("is_verified", .boolean).notNull().defaults(to: false)
            t.column("confidence", .double).notNull()
            t.column("evidence", .text).notNull()
            t.column("created_at", .datetime).notNull()
        }
        try db.create(
            index: "file_relationships_unique",
            on: "file_relationships",
            columns: ["source_file_id", "target_file_id", "kind"],
            unique: true
        )

        try db.create(table: "file_actions") { t in
            t.autoIncrementedPrimaryKey("id")
            t.column("file_id", .integer).indexed().references("files", onDelete: .setNull)
            t.column("batch_id", .text)
            t.column("action_type", .text).notNull()
            t.column("original_path", .text).notNull()
            t.column("destination_path", .text)
            t.column("detail", .text)
            t.column("performed_at", .datetime).notNull().indexed()
            t.column("result", .text).notNull()
            t.column("error_details", .text)
            t.column("recovery_info", .text)
        }

        try db.create(table: "category_rules") { t in
            t.autoIncrementedPrimaryKey("id")
            t.column("match_kind", .text).notNull()
            t.column("pattern", .text).notNull()
            t.column("category_id", .integer).notNull().indexed().references("categories", onDelete: .cascade)
            t.column("priority", .integer).notNull().defaults(to: 0)
            t.column("is_enabled", .boolean).notNull().defaults(to: true)
            t.column("origin", .text).notNull()
            t.column("note", .text)
            t.column("created_at", .datetime).notNull()
        }

        try db.create(table: "user_preferences") { t in
            t.column("key", .text).primaryKey()
            t.column("value", .text).notNull()
            t.column("updated_at", .datetime).notNull()
        }
    }

    // MARK: - Seed data

    struct SeedCategory {
        let slug: String
        let name: String
        let description: String
    }

    static let technicalCategories: [SeedCategory] = [
        SeedCategory(slug: "documents", name: "Documents", description: "PDFs, word-processing files and text documents."),
        SeedCategory(slug: "images", name: "Images", description: "Photos, screenshots and other raster or vector images."),
        SeedCategory(slug: "video", name: "Video", description: "Movies and video recordings."),
        SeedCategory(slug: "audio", name: "Audio", description: "Music, podcasts and sound recordings."),
        SeedCategory(slug: "archives", name: "Archives", description: "Compressed archives and disk images that are not installers."),
        SeedCategory(slug: "applications", name: "Applications", description: "Application bundles and executables."),
        SeedCategory(slug: "installers", name: "Installers", description: "Installer packages and installer disk images."),
        SeedCategory(slug: "source-code", name: "Source Code", description: "Program source files and scripts."),
        SeedCategory(slug: "spreadsheets", name: "Spreadsheets", description: "Spreadsheet workbooks."),
        SeedCategory(slug: "presentations", name: "Presentations", description: "Slide decks."),
        SeedCategory(slug: "design-assets", name: "Design Assets", description: "Design, 3D and creative project files."),
        SeedCategory(slug: "databases", name: "Databases", description: "Database files."),
        SeedCategory(slug: "datasets", name: "Datasets", description: "Tabular and structured data files."),
        SeedCategory(slug: "fonts", name: "Fonts", description: "Font files."),
        SeedCategory(slug: "configuration", name: "Configuration Files", description: "Settings, manifests and configuration files."),
        SeedCategory(slug: "temporary", name: "Temporary Files", description: "Partial downloads, lock files and other temporary items."),
        SeedCategory(slug: "unknown", name: "Unknown", description: "Items whose type could not be determined with confidence."),
    ]

    static let semanticCategories: [SeedCategory] = [
        SeedCategory(slug: "academic", name: "Academic Materials", description: "Course and study material."),
        SeedCategory(slug: "research-papers", name: "Research Papers", description: "Papers, theses and preprints."),
        SeedCategory(slug: "lecture-notes", name: "Lecture Notes", description: "Notes and slides from lectures."),
        SeedCategory(slug: "assignments", name: "Assignments", description: "Homework and coursework."),
        SeedCategory(slug: "financial", name: "Financial Documents", description: "Statements, tax and banking documents."),
        SeedCategory(slug: "invoices-receipts", name: "Invoices and Receipts", description: "Invoices, bills and receipts."),
        SeedCategory(slug: "legal", name: "Legal Documents", description: "Contracts and agreements."),
        SeedCategory(slug: "work", name: "Work Documents", description: "Work-related documents."),
        SeedCategory(slug: "project-docs", name: "Project Documentation", description: "Specifications, READMEs and design documents."),
        SeedCategory(slug: "personal-records", name: "Personal Records", description: "Personal records and identity documents."),
        SeedCategory(slug: "reference", name: "Reference Materials", description: "Manuals, books and reference material."),
        SeedCategory(slug: "certificates", name: "Certificates", description: "Certificates and awards."),
        SeedCategory(slug: "reports", name: "Reports", description: "Reports and analyses."),
    ]

    private static func seedCategories(_ db: Database) throws {
        for (index, category) in technicalCategories.enumerated() {
            try db.execute(
                sql: """
                INSERT INTO categories (slug, name, description, kind, is_system, sort_order)
                VALUES (?, ?, ?, ?, 1, ?)
                """,
                arguments: [category.slug, category.name, category.description, CategoryKind.technical.rawValue, index]
            )
        }
        let documentsId = try Int64.fetchOne(db, sql: "SELECT id FROM categories WHERE slug = 'documents'")
        for (index, category) in semanticCategories.enumerated() {
            try db.execute(
                sql: """
                INSERT INTO categories (slug, name, parent_id, description, kind, is_system, sort_order)
                VALUES (?, ?, ?, ?, ?, 1, ?)
                """,
                arguments: [category.slug, category.name, documentsId, category.description, CategoryKind.semantic.rawValue, 100 + index]
            )
        }
    }
}
