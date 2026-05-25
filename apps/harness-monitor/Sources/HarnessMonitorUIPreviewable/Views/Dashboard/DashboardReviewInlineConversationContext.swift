import HarnessMonitorKit
import SwiftUI

/// Per-file inline conversation inputs handed to the diff canvas: the file's
/// threads, the active visibility mode, and the async resolve/reply ports plus
/// avatar loader. Carried through the SwiftUI environment so the AppKit diff
/// grid can host cards without every diff wrapper (`Unified` / `Split` /
/// `Preview`) re-declaring six parameters across two initializers each.
struct DashboardReviewInlineConversationContext {
  var threads: [DashboardReviewFileThread]
  var visibility: ConversationVisibility
  var viewerLogin: String?
  var loadAvatar: TimelineAvatarImageLoader?
  var onResolveToggle: (String, Bool) async -> Void
  var onReply: (String, String) async -> Bool
}

extension EnvironmentValues {
  /// `nil` means inline conversations are not wired for this subtree, so the
  /// diff canvas renders exactly as it did before the feature (flat grid).
  @Entry var reviewInlineConversationContext: DashboardReviewInlineConversationContext?
}
