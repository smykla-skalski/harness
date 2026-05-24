import SwiftUI

/// Per-state-cache announcer so two open session windows don't clobber each
/// other's pending VoiceOver post.
@MainActor
public final class SessionSidebarMultiSelectAnnouncer {
  private static let debounceInterval: Duration = .milliseconds(150)

  private var pendingTask: Task<Void, Never>?

  public init() {}

  public func announce(
    kind: SessionSidebarSelectionKind,
    count: Int,
    visibleCount: Int
  ) {
    let summary = Self.announcementCopy(
      kind: kind,
      count: count,
      visibleCount: visibleCount
    )
    pendingTask?.cancel()
    pendingTask = Task { @MainActor in
      try? await Task.sleep(for: Self.debounceInterval)
      guard !Task.isCancelled else { return }
      AccessibilityNotification.Announcement(summary).post()
    }
  }

  public static func announcementCopy(
    kind: SessionSidebarSelectionKind,
    count: Int,
    visibleCount: Int
  ) -> String {
    if count == 0 {
      return "Selection cleared"
    }
    return "\(count) of \(visibleCount) \(kind.pluralNoun) selected"
  }
}
