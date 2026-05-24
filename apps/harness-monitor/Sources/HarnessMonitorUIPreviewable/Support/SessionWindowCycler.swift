import AppKit

public enum SessionWindowCycleDirection {
  case forward
  case backward
}

/// Cycles the key window across every visible app window, expanding native
/// `NSWindow` tab groups so each tab participates in the rotation.
///
/// AppKit's stock `Cycle Through Windows` (Cmd+`) walks `NSApp.windows` in
/// last-key order, so siblings merged into a tab group skip the rotation —
/// only the currently-selected tab is reachable. This helper rebuilds the
/// candidate set by expanding `tabbedWindows`, then activates the next entry
/// by selecting it inside its tab group before calling `makeKeyAndOrderFront`.
public enum SessionWindowCycler {
  /// Pure index advancement, extracted so the rotation contract is testable
  /// without spinning up real `NSWindow` instances.
  public static func nextIndex(
    currentIndex: Int,
    count: Int,
    direction: SessionWindowCycleDirection
  ) -> Int {
    precondition(count > 0, "nextIndex requires at least one candidate")
    let normalized = ((currentIndex % count) + count) % count
    switch direction {
    case .forward:
      return (normalized + 1) % count
    case .backward:
      return (normalized - 1 + count) % count
    }
  }

  @MainActor
  public static func cycle(direction: SessionWindowCycleDirection) {
    let candidates = orderedCandidates()
    guard candidates.count > 1 else {
      return
    }
    let key = NSApplication.shared.keyWindow
    let currentIndex =
      key.flatMap { current in
        candidates.firstIndex { $0 === current }
      } ?? 0
    let next = candidates[
      nextIndex(currentIndex: currentIndex, count: candidates.count, direction: direction)
    ]
    activate(next)
  }

  /// Visible, key-eligible app windows in display order, expanded across tab
  /// groups so every native tab appears as its own rotation entry.
  @MainActor
  static func orderedCandidates() -> [NSWindow] {
    var seen = Set<ObjectIdentifier>()
    var ordered: [NSWindow] = []
    for window in NSApplication.shared.orderedWindows {
      let group = window.tabbedWindows ?? [window]
      for member in group where isEligible(member) {
        if seen.insert(ObjectIdentifier(member)).inserted {
          ordered.append(member)
        }
      }
    }
    return ordered
  }

  @MainActor
  private static func isEligible(_ window: NSWindow) -> Bool {
    window.isVisible && !window.isMiniaturized && window.canBecomeKey
  }

  @MainActor
  private static func activate(_ window: NSWindow) {
    if let group = window.tabGroup, group.selectedWindow !== window {
      group.selectedWindow = window
    }
    window.makeKeyAndOrderFront(nil)
  }
}
