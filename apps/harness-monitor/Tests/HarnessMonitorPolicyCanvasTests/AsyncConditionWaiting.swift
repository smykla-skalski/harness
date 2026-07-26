import Foundation

/// Waits for `predicate` against a clock instead of a number of yields.
///
/// A bounded `Task.yield()` loop is not a progress guarantee. Yielding offers
/// the executor a chance to run something else, but under load the work being
/// waited on can stay unscheduled through every one of them, so the loop ends
/// early and the test reports a failure the code never had. It also spins a
/// core for the whole bound, which starves the wall-clock budgets other suites
/// assert on.
@MainActor
func waitUntil(
  timeout: Duration = .seconds(1),
  interval: Duration = .milliseconds(10),
  _ predicate: @escaping @Sendable @MainActor () -> Bool
) async -> Bool {
  let deadline = ContinuousClock.now.advanced(by: timeout)
  while ContinuousClock.now < deadline {
    if predicate() { return true }
    do {
      try await Task.sleep(for: interval)
    } catch {
      // A cancelled task makes every later sleep throw immediately, so
      // swallowing this would busy-spin until the deadline.
      return false
    }
  }
  // One last look: the predicate may have landed while the final sleep ran.
  return predicate()
}
