# Version History

## 0.2.0

- Add file actions: Archive moves selected items into a chosen folder without replacing anything, and Move to Trash moves items to the Trash after confirmation. Both are logged in Activity.
- Add notifications for finished full scans with changes, failed scans, unavailable locations, stopped processing and finished file actions.
- Fix test target compile errors (missing `await` on database reads).

## 0.1.0

- Initial version: indexed locations, universal index with reliable rescans, metadata, classification, exact duplicates, review priority and the SwiftUI interface.
