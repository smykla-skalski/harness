import HarnessMonitorKit
import SwiftUI

extension DashboardReviewFilesModeDetailPane {
  /// In-view control that cycles inline-conversation visibility for the
  /// session (Hidden -> Unresolved only -> All), overriding the Settings
  /// default without persisting. Mirrors the ⌘⌥⇧C menu command.
  var conversationVisibilityToggle: some View {
    Menu {
      conversationVisibilityMenuItem(.hidden)
      conversationVisibilityMenuItem(.unresolved)
      conversationVisibilityMenuItem(.all)
    } label: {
      HStack(spacing: 6) {
        Image(systemName: effectiveConversationVisibility.systemImage)
        Text("Conversations")
        Text(effectiveConversationVisibility.menuTitle)
          .foregroundStyle(HarnessMonitorTheme.secondaryInk)
        Image(systemName: "chevron.down")
          .imageScale(.small)
          .foregroundStyle(HarnessMonitorTheme.secondaryInk)
      }
      .lineLimit(1)
    }
    .menuStyle(.button)
    .menuIndicator(.hidden)
    .harnessActionButtonStyle(variant: .bordered, tint: .secondary)
    .fixedSize(horizontal: true, vertical: true)
    .help("Choose which inline conversations appear in the diff (⌘⌥⇧C cycles).")
    .accessibilityLabel("Inline conversations")
    .accessibilityValue(effectiveConversationVisibility.menuTitle)
    .accessibilityHint("Choose which inline conversations appear in the diff.")
    .accessibilityIdentifier("dashboardReviewFilesConversationVisibilityToggle")
  }

  private func conversationVisibilityMenuItem(_ visibility: ConversationVisibility) -> some View {
    Button {
      setConversationVisibility(visibility)
    } label: {
      if effectiveConversationVisibility == visibility {
        Label(visibility.menuTitle, systemImage: "checkmark")
      } else {
        Label(visibility.menuTitle, systemImage: visibility.systemImage)
      }
    }
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
