import Foundation

/// Tracks which dependency pull requests have a mutation or refresh in flight,
/// using reference counting so concurrent actions on the same PR don't clear
/// the row indicator until every operation completes.
///
/// Holds an optional per-PR action title ("Approving", "Merging", etc.) the row
/// uses for a VoiceOver label more specific than the generic fallback.
struct DependencyRefreshTracker: Equatable, Sendable {
  private(set) var counts: [String: Int] = [:]
  private(set) var actionTitles: [String: String] = [:]

  func isRefreshing(_ pullRequestID: String) -> Bool {
    (counts[pullRequestID] ?? 0) > 0
  }

  func actionTitle(for pullRequestID: String) -> String? {
    actionTitles[pullRequestID]
  }

  mutating func begin(pullRequestIDs ids: [String], actionTitle title: String? = nil) {
    for id in ids {
      counts[id, default: 0] += 1
      if let title {
        actionTitles[id] = title
      }
    }
  }

  mutating func end(pullRequestIDs ids: [String]) {
    for id in ids {
      let next = (counts[id] ?? 0) - 1
      if next > 0 {
        counts[id] = next
      } else {
        counts.removeValue(forKey: id)
        actionTitles.removeValue(forKey: id)
      }
    }
  }
}
