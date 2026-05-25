import HarnessMonitorKit
import SwiftUI

/// Snippet rendered alongside the `GetNeedsMeCountIntent` result.
/// Siri, Spotlight, and Apple Intelligence render this view inline
/// instead of just speaking the count, so users see at a glance which
/// PRs are stacking up
///
/// Designed for the small width that snippets get on macOS - one
/// headline + up to three secondary lines. Long PR titles truncate
/// rather than wrap to keep the snippet height bounded
public struct NeedsMeCountSnippetView: View {
  let count: Int
  let topItems: [ReviewItem]

  /// Marked `nonisolated` so the App Intent's `perform()` can build
  /// the view from a non-MainActor context. SwiftUI still renders the
  /// body on the MainActor; only the value-init runs outside it
  nonisolated public init(count: Int, topItems: [ReviewItem]) {
    self.count = count
    self.topItems = topItems
  }

  public var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack(alignment: .firstTextBaseline, spacing: 6) {
        Image(systemName: "checklist.checked")
          .foregroundStyle(.tint)
        Text(headline)
          .font(.headline)
      }

      if !topItems.isEmpty {
        VStack(alignment: .leading, spacing: 4) {
          ForEach(topItems.prefix(3), id: \.pullRequestID) { item in
            HStack(alignment: .firstTextBaseline, spacing: 6) {
              Text(item.repository)
                .font(.caption2.monospaced())
                .foregroundStyle(.secondary)
              Text(item.title)
                .font(.caption)
                .lineLimit(1)
            }
          }
        }
      }
    }
    .padding(12)
  }

  private var headline: String {
    switch count {
    case 0: "Nothing waiting on you"
    case 1: "1 pull request needs your review"
    default: "\(count) pull requests need your review"
    }
  }
}
