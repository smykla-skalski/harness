import Foundation

/// How inline review conversations are shown in the Files diff. Persisted as a
/// raw string in ``DashboardReviewsPreferences`` and overridable per session by
/// the in-view toggle and the cycle-visibility keyboard shortcut.
enum ConversationVisibility: String, CaseIterable, Codable, Equatable, Sendable {
  /// No inline conversations are rendered in the diff.
  case hidden
  /// Only unresolved conversations are rendered; resolved ones are omitted.
  case unresolved
  /// Every conversation is rendered, with resolved ones marked as such.
  case all

  /// Title shown in the Settings picker and the in-view cycle control.
  var menuTitle: String {
    switch self {
    case .hidden: "Hidden"
    case .unresolved: "Unresolved only"
    case .all: "All"
    }
  }

  /// SF Symbol paired with ``menuTitle`` in menus and toolbar controls.
  var systemImage: String {
    switch self {
    case .hidden: "eye.slash"
    case .unresolved: "exclamationmark.bubble"
    case .all: "bubble.left.and.bubble.right"
    }
  }

  /// Whether a thread with the given resolved state renders under this mode.
  func shows(isResolved: Bool) -> Bool {
    switch self {
    case .hidden: false
    case .unresolved: !isResolved
    case .all: true
    }
  }

  /// Next mode in the Hidden -> Unresolved -> All -> Hidden cycle driven by the
  /// in-view toggle button and the keyboard shortcut.
  var cycledNext: ConversationVisibility {
    switch self {
    case .hidden: .unresolved
    case .unresolved: .all
    case .all: .hidden
    }
  }
}

extension DashboardReviewsPreferences {
  /// Typed accessor over ``filesConversationVisibilityRaw``. Unknown raw values
  /// fall back to ``ConversationVisibility/all`` so a corrupt or forward-version
  /// string still shows conversations rather than silently hiding them.
  var filesConversationVisibility: ConversationVisibility {
    ConversationVisibility(rawValue: filesConversationVisibilityRaw) ?? .all
  }
}
