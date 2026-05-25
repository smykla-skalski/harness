import HarnessMonitorKit
import SwiftUI

extension DashboardReviewFilesModeDetailPane {
  /// In-view control that cycles inline-conversation visibility for the
  /// session (Hidden -> Unresolved only -> All), overriding the Settings
  /// default without persisting. Mirrors the ⌘⌥⇧C menu command.
  var conversationVisibilityToggle: some View {
    DashboardReviewActionButton(
      title: "Threads: \(effectiveConversationVisibility.menuTitle)",
      systemImage: effectiveConversationVisibility.systemImage,
      prominence: .secondary,
      helpText: "Inline conversations: \(effectiveConversationVisibility.menuTitle) (⌘⌥⇧C)",
      action: cycleConversationVisibility
    )
    .accessibilityLabel("Cycle inline conversations")
    .accessibilityValue(effectiveConversationVisibility.menuTitle)
    .accessibilityHint(
      "Cycles between hidden, unresolved only, and all inline conversations"
    )
    .accessibilityIdentifier("dashboardReviewFilesConversationVisibilityToggle")
  }

  /// Per-file inline conversation inputs handed to the diff canvas through the
  /// environment: the file's threads, the effective visibility, and the async
  /// resolve/reply/avatar ports backed by the store.
  func conversationContext(
    file: ReviewFile,
    threads: [DashboardReviewFileThread]
  ) -> DashboardReviewInlineConversationContext {
    DashboardReviewInlineConversationContext(
      threads: threads,
      visibility: effectiveConversationVisibility,
      viewerLogin: viewerLogin,
      loadAvatar: { login, avatarURL, targetPixel in
        await store.reviewAvatarImage(
          login: login,
          avatarURL: avatarURL,
          targetPixel: targetPixel
        )
      },
      onResolveToggle: { threadID, desired in
        _ = await store.setReviewThreadResolved(
          threadID: threadID,
          pullRequestID: item.pullRequestID,
          desired: desired
        )
      },
      onReply: { threadID, body in
        guard let thread = threads.first(where: { $0.id == threadID }) else { return false }
        return await store.postReviewFileComment(
          pullRequestID: item.pullRequestID,
          repository: item.repository,
          draft: .reply(file: file, thread: thread.anchor),
          body: body,
          viewerLogin: viewerLogin
        )
      }
    )
  }
}
