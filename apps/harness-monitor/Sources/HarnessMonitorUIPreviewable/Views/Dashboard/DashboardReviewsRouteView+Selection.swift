import Foundation

/// Pure helper that picks the primary selection ID from a `Set<String>` delta.
///
/// The primary selection is the PR shown in the detail pane when multiple PRs
/// are selected. Picking the lexical `min` of the new selection drops user
/// intent on the floor: clicking a single new row should make THAT row primary,
/// regardless of where its ID sorts.
///
/// Resolution is delta-aware:
///
/// - If exactly one ID was added in this change, that ID becomes the new primary.
///   This is the canonical "user clicked one row" path.
/// - If more than one ID was added in a single change, this looks like a
///   select-all or programmatic bulk add. Fall back to the lexical first
///   (`newSelection.min()`) so the behavior is stable.
/// - If no IDs were added (a pure deselect or no-op), keep the existing primary
///   if it is still in `newSelection`. Otherwise fall back to the lexical first.
///
/// The helper never mutates state and never returns a primary that is not in
/// `newSelection` unless `newSelection` is empty, in which case it falls back
/// to `currentPrimary` so the persisted "last seen" PR survives transient
/// empties.
enum DashboardReviewsPrimarySelectionResolver {
  static func resolve(
    oldSelection: Set<String>,
    newSelection: Set<String>,
    currentPrimary: String
  ) -> String {
    if newSelection.isEmpty {
      // Leave the persisted primary alone so the detail pane can keep its
      // last-seen PR when selection clears.
      return currentPrimary
    }
    let delta = newSelection.subtracting(oldSelection)
    if delta.count == 1, let onlyAddition = delta.first {
      return onlyAddition
    }
    if delta.count > 1 {
      return newSelection.min() ?? currentPrimary
    }
    // delta is empty: either a pure deselect or a no-op. Keep the existing
    // primary if it survived; otherwise fall back to the lexical first.
    if newSelection.contains(currentPrimary) {
      return currentPrimary
    }
    return newSelection.min() ?? currentPrimary
  }
}
