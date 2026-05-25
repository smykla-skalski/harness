import SwiftUI

/// Scene-level command published while the Reviews Files diff is on screen so
/// the Reviews menu's "Cycle Inline Conversations" item (⌘⌥⇧C) can drive the
/// in-view visibility cycle. `nil` when Files mode isn't shown, which disables
/// the menu command. `currentTitle` carries the active mode for the menu label;
/// the ``ConversationVisibility`` enum itself stays internal to this module.
public struct DashboardReviewFilesConversationCommand: Equatable, @unchecked Sendable {
  public let currentTitle: String
  public let cycle: () -> Void

  public init(currentTitle: String, cycle: @escaping () -> Void) {
    self.currentTitle = currentTitle
    self.cycle = cycle
  }

  public static func == (lhs: Self, rhs: Self) -> Bool {
    lhs.currentTitle == rhs.currentTitle
  }
}

extension FocusedValues {
  @Entry public var dashboardReviewFilesConversationCommand:
    DashboardReviewFilesConversationCommand?
}
