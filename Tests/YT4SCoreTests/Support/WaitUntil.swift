import Foundation

/// Polls `condition` until it holds.
///
/// Deliberately has no deadline of its own: a wall-clock budget turns a slow (loaded) machine
/// into a red test. A test that waits here carries a coarse `.timeLimit` instead, which only
/// catches a real hang. Pair it with the fake's `Hold` so the state waited for cannot slip by.
func waitUntil(isolation: isolated (any Actor)? = #isolation, _ condition: () -> Bool) async throws {
    while !condition() {
        try await Task.sleep(for: .milliseconds(10))
    }
}
