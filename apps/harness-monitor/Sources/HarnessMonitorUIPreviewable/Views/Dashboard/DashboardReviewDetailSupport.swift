import HarnessMonitorKit
import SwiftUI

/// Identifier for each detail-pane section. Used as the `.id()` anchor
/// for the Jump-to menu's `ScrollViewReader.scrollTo(_:anchor:)`.
enum DashboardReviewDetailSectionID: String, CaseIterable {
  case description
  case files
  case checks
  case activity
  case reviews
  case labels
  case conversation
  case comment

  var menuTitle: String {
    switch self {
    case .description: "Description"
    case .files: "Files"
    case .checks: "Checks"
    case .activity: "Activity"
    case .reviews: "Reviews"
    case .labels: "Labels"
    case .conversation: "Conversation"
    case .comment: "Comment"
    }
  }
}

func dashboardReviewDetailJumpTargets(
  filesEnabled: Bool,
  filesHiddenForCurrentPR: Bool,
  showsConversation: Bool
) -> [DashboardReviewDetailSectionID] {
  // Files always anchors something: the live section, global-disabled
  // placeholder, or per-PR-dismissed placeholder.
  DashboardReviewDetailSectionID.allCases.filter { id in
    switch id {
    case .conversation:
      return showsConversation
    default:
      return true
    }
  }
}

struct DashboardReviewFilesHiddenPlaceholder: View {
  let message: String
  let actionTitle: String
  let onAction: () -> Void

  var body: some View {
    HStack(alignment: .firstTextBaseline, spacing: HarnessMonitorTheme.spacingSM) {
      Image(systemName: "eye.slash")
        .foregroundStyle(HarnessMonitorTheme.secondaryInk)
      Text(message)
        .scaledFont(.callout)
        .foregroundStyle(HarnessMonitorTheme.secondaryInk)
        .fixedSize(horizontal: false, vertical: true)
      Spacer(minLength: HarnessMonitorTheme.spacingSM)
      Button(actionTitle, action: onAction)
        .controlSize(.small)
    }
  }
}

struct DashboardReviewDetailHeader<Actions: View>: View {
  let item: ReviewItem
  let jumpTargets: [DashboardReviewDetailSectionID]
  let onJumpTo: (String) -> Void
  @ViewBuilder let actionBar: () -> Actions

  @Environment(\.openURL)
  private var openURL

  private var pullRequestURL: URL? {
    URL(string: item.url)
  }

  private var authorProfileURL: URL? {
    URL(string: "https://github.com/\(item.authorLogin)")
  }

  var body: some View {
    VStack(alignment: .leading, spacing: HarnessMonitorTheme.spacingMD) {
      VStack(alignment: .leading, spacing: HarnessMonitorTheme.spacingXS) {
        HStack(alignment: .top, spacing: HarnessMonitorTheme.spacingSM) {
          Button {
            if let pullRequestURL {
              openURL(pullRequestURL)
            }
          } label: {
            Text(item.title)
              .scaledFont(.system(.title2, design: .rounded, weight: .semibold))
              .foregroundStyle(HarnessMonitorTheme.ink)
              .lineLimit(2)
              .truncationMode(.tail)
              .fixedSize(horizontal: false, vertical: true)
              .frame(maxWidth: .infinity, alignment: .leading)
          }
          .harnessPlainButtonStyle()
          .disabled(pullRequestURL == nil)
          .help("Open pull request on GitHub")
          .accessibilityHint("Opens the pull request on GitHub")

          jumpToMenu
        }

        HStack(spacing: 0) {
          Text("\(item.repository)")
          Button {
            if let pullRequestURL {
              openURL(pullRequestURL)
            }
          } label: {
            Text("#\(item.number)")
          }
          .harnessPlainButtonStyle()
          .disabled(pullRequestURL == nil)
          .help("Open pull request on GitHub")
          .accessibilityHint("Opens the pull request on GitHub")
          Text(" · @")
          Button {
            if let authorProfileURL {
              openURL(authorProfileURL)
            }
          } label: {
            Text(item.authorLogin)
          }
          .harnessPlainButtonStyle()
          .disabled(authorProfileURL == nil)
          .help("Open author profile on GitHub")
          .accessibilityHint("Opens the author profile on GitHub")
        }
        .scaledFont(.callout.weight(.semibold))
        .foregroundStyle(HarnessMonitorTheme.secondaryInk)
      }

      actionBar()
      DashboardReviewStatusStrip(item: item)
      if item.requiresAttention {
        DashboardReviewAttentionSummary(item: item)
      }
    }
    .frame(maxWidth: reviewsDetailMaxWidth, alignment: .leading)
    .padding(.bottom, HarnessMonitorTheme.spacingMD)
    // No bottom divider here: the first section already owns the top divider.
  }

  @ViewBuilder private var jumpToMenu: some View {
    Menu {
      ForEach(jumpTargets, id: \.self) { target in
        Button(target.menuTitle) {
          onJumpTo(target.rawValue)
        }
      }
    } label: {
      Image(systemName: "list.bullet.rectangle")
        .imageScale(.medium)
        .padding(.horizontal, 6)
        .padding(.vertical, 4)
        .contentShape(.rect)
    }
    .menuStyle(.borderlessButton)
    .menuIndicator(.hidden)
    .fixedSize()
    .help("Jump to section")
    .accessibilityLabel(Text("Jump to section"))
  }
}

struct DashboardReviewDetailCard<Content: View>: View {
  let title: String
  let subtitle: String
  @ViewBuilder let content: () -> Content

  var body: some View {
    VStack(alignment: .leading, spacing: HarnessMonitorTheme.spacingMD) {
      Text(title)
        .scaledFont(.system(.title2, design: .rounded, weight: .semibold))
        .foregroundStyle(HarnessMonitorTheme.ink)
        .lineLimit(3)
        .fixedSize(horizontal: false, vertical: true)
      Text(subtitle)
        .scaledFont(.callout.weight(.semibold))
        .foregroundStyle(HarnessMonitorTheme.secondaryInk)
      content()
    }
    .frame(maxWidth: reviewsDetailMaxWidth, alignment: .leading)
    .padding(.bottom, HarnessMonitorTheme.spacingLG)
    .overlay(alignment: .bottom) {
      Divider().opacity(0.42)
    }
  }
}

struct DashboardReviewDetailSection<Content: View>: View {
  let title: String?
  @ViewBuilder let content: () -> Content

  var body: some View {
    VStack(alignment: .leading, spacing: HarnessMonitorTheme.spacingSM) {
      if let title {
        Text(title)
          .scaledFont(.subheadline.weight(.semibold))
          .foregroundStyle(HarnessMonitorTheme.ink)
      }
      content()
    }
    .frame(maxWidth: reviewsDetailMaxWidth, alignment: .leading)
    .padding(.vertical, HarnessMonitorTheme.spacingMD)
    .overlay(alignment: .top) {
      Divider().opacity(0.40)
    }
  }
}
