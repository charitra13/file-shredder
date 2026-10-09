import Foundation

/// Transforms `items` with at most `maxConcurrency` operations in flight. Result order is not preserved.
func concurrentMap<Item: Sendable, Output: Sendable>(
    _ items: [Item],
    maxConcurrency: Int,
    _ transform: @escaping @Sendable (Item) async throws -> Output
) async throws -> [Output] {
    let limit = max(1, maxConcurrency)
    return try await withThrowingTaskGroup(of: Output.self) { group in
        var results: [Output] = []
        results.reserveCapacity(items.count)
        var iterator = items.makeIterator()

        for _ in 0..<limit {
            guard let item = iterator.next() else { break }
            group.addTask { try await transform(item) }
        }
        while let output = try await group.next() {
            results.append(output)
            if let item = iterator.next() {
                try Task.checkCancellation()
                group.addTask { try await transform(item) }
            }
        }
        return results
    }
}

/// Runs a cooperative operation with a deadline. The operation must honour cancellation.
func withTimeout<Output: Sendable>(
    seconds: Double,
    _ operation: @escaping @Sendable () async throws -> Output
) async throws -> Output {
    try await withThrowingTaskGroup(of: Output.self) { group in
        group.addTask { try await operation() }
        group.addTask {
            try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            throw FileIntelligenceError.timedOut
        }
        defer { group.cancelAll() }
        guard let first = try await group.next() else {
            throw FileIntelligenceError.timedOut
        }
        return first
    }
}
