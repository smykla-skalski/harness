import Foundation

/// Pure presentation logic for a single inline review conversation card.
/// Kept separate from the SwiftUI view so the header/line/resolve mapping is
/// unit-testable with hand-built ``DashboardReviewFileThread`` fixtures (the
/// contract is deterministic: thread shape in, display strings out).
struct DashboardReviewInlineThreadCardModel: Equatable {
  let thread: DashboardReviewFileThread

  init(thread: DashboardReviewFileThread) {
    self.thread = thread
  }

  var isResolved: Bool {
    thread.isResolved
  }

  /// Author shown in the card header: the thread starter, falling back to the
  /// first comment's author, then a neutral placeholder.
  var headerAuthorLogin: String {
    thread.authorLogin ?? thread.comments.first?.authorLogin ?? "unknown"
  }

  /// Diff anchor shown next to the author. GitHub labels threads whose line no
  /// longer maps into the current diff as "Outdated".
  var lineReference: String {
    if let line = thread.line {
      return "Line \(line)"
    }
    return "Outdated"
  }

  var resolveActionTitle: String {
    thread.isResolved ? "Unresolve" : "Resolve"
  }

  var resolveActionSystemImage: String {
    thread.isResolved ? "arrow.uturn.backward.circle" : "checkmark.circle"
  }

  /// Chip text shown only while the thread is resolved; `nil` hides the chip.
  var resolvedChipText: String? {
    thread.isResolved ? "Resolved" : nil
  }

  /// Footer summary, pluralized on the real comment count.
  var commentSummary: String {
    let count = thread.comments.count
    return count == 1 ? "1 comment" : "\(count) comments"
  }
}
