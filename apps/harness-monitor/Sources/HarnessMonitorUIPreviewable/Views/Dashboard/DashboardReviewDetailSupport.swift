import HarnessMonitorKit
import SwiftUI

/// Identifier for each detail-pane section. Used as the `.id()` anchor
/// for the Jump-to menu's `ScrollViewReader.scrollTo(_:anchor:)`.
enum DashboardReviewDetailSectionID: String, CaseIterable {
  case description
  case activity
  case labels

  var menuTitle: String {
    switch self {
    case .description: "Description"
    case .activity: "Activity"
    case .labels: "Labels"
    }
  }
}

func dashboardReviewDetailJumpTargets() -> [DashboardReviewDetailSectionID] {
  DashboardReviewDetailSectionID.allCases
}

struct DashboardReviewDetailModeSwitcher: View {
  @Binding var detailMode: DashboardReviewsDetailMode
  let filesAvailable: Bool

  var body: some View {
    HarnessMonitorGlassControlGroup(spacing: HarnessMonitorTheme.spacingXS) {
      HStack(spacing: HarnessMonitorTheme.spacingXS) {
        modeButton(
          .overview,
          title: "Overview",
          helpText: "Show the pull request overview",
          accessibilityIdentifier:
            HarnessMonitorAccessibility.dashboardReviewsOverviewModeButton
        )
        modeButton(
          .files,
          title: "Files",
          helpText:
            filesAvailable
            ? "Show changed files"
            : "Files are unavailable for the current selection",
          accessibilityIdentifier: HarnessMonitorAccessibility.dashboardReviewsFilesModeButton
        )
      }
    }
    .accessibilityIdentifier(HarnessMonitorAccessibility.dashboardReviewsModeSwitcher)
  }

  private func modeButton(
    _ mode: DashboardReviewsDetailMode,
    title: String,
    helpText: String,
    accessibilityIdentifier: String
  ) -> some View {
    let isSelected = detailMode == mode
    return Button {
      detailMode = mode
    } label: {
      Text(title)
        .lineLimit(1)
    }
    .harnessActionButtonStyle(
      variant: isSelected ? .prominent : .bordered,
      tint: isSelected ? nil : .secondary
    )
    .fixedSize(horizontal: true, vertical: true)
    .accessibilityLabel(title)
    .accessibilityValue(isSelected ? "Selected" : "Not selected")
    .accessibilityHint(helpText)
    .accessibilityIdentifier(accessibilityIdentifier)
    .help(helpText)
    .disabled(mode == .files && !filesAvailable)
  }
}

struct DashboardReviewDetailHeader<Actions: View>: View {
  let item: ReviewItem
  @Binding var detailMode: DashboardReviewsDetailMode
  let filesModeAvailable: Bool
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

          HStack(spacing: HarnessMonitorTheme.spacingSM) {
            DashboardReviewDetailModeSwitcher(
              detailMode: $detailMode,
              filesAvailable: filesModeAvailable
            )
            jumpToMenu
          }
        }

        HStack(spacing: 0) {
          Text("\(item.repository)")
          Button {
            if let pullRequestURL {
              openURL(pullRequestURL)
            }
          } label: {
            Text(verbatim: "#\(item.number)")
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
