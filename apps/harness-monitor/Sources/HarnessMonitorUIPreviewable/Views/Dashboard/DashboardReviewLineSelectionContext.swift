import HarnessMonitorKit
import SwiftUI

/// Per-file line-selection inputs handed to the diff canvas: the line range to
/// highlight and scroll to (driven by navigation history and `harness://` deep
/// links), a callback for the gutter selections a reviewer makes, and the pull
/// request ID so the grid can build shareable `harness://` links. Carried
/// through the environment so `Unified` / `Split` / `Preview` need no extra
/// parameters, mirroring `DashboardReviewInlineConversationContext`.
struct DashboardReviewLineSelectionContext {
  var pullRequestID: String
  var selection: ReviewLineSelection?
  var onSelectLines: (@MainActor (ReviewLineSelection?) -> Void)?
}

extension EnvironmentValues {
  /// `nil` means line selection is not wired for this subtree, so the diff
  /// canvas keeps its previous behavior (local highlight only, no history).
  @Entry var reviewLineSelectionContext: DashboardReviewLineSelectionContext?
}
