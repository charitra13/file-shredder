# Version History

## 0.3.1

- Refuse to move files to the Trash when their identity or metadata changed since indexing.
- Reconcile only source folders after Trash actions so trashed items stay out of file lists.
- Preserve completed moves and rescan affected folders when saving activity or scoring fails.
- Add regression tests for Trash actions and correct the documented build status.

## 0.3.0

- Add Quick Look: press Space in a file list to preview the selected files.
- Add ⌘⌫ in a file list to move the selected files to the Trash (with confirmation).
- Fix the bundle version so the app reports its marketing version.

## 0.2.0

- Add Move to Trash: moves selected items to the Trash after confirmation and logs each one in Activity.
- Add notifications for finished full scans with changes, failed scans, unavailable locations, stopped processing and finished Move to Trash actions.
- Fix test target compile errors (missing `await` on database reads).

## 0.1.0

- Initial version: indexed locations, universal index with reliable rescans, metadata, classification, exact duplicates, review priority and the SwiftUI interface.
