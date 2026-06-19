import HarnessMonitorKit
import SwiftUI

/// Identifier for each detail-pane section. Used as the `.id()` anchor
/// for the Jump-to menu's `ScrollViewReader.scrollTo(_:anchor:)`.
enum DashboardReviewDetailSectionID: String, CaseIterable {
  case description
  case activity
  case labels
  case moreDetails

  var menuTitle: String {
    switch self {
    case .description: "Description"
    case .activity: "Activity"
    case .labels: "Labels"
    case .moreDetails: "More details"
    }
  }
}

func dashboardReviewDetailJumpTargets() -> [DashboardReviewDetailSectionID] {
  DashboardReviewDetailSectionID.allCases
}

enum DashboardReviewsFilesModeAvailability: Equatable {
  case available
  case disabledInPreferences
  case requiresSingleSelection
  case requiresSelection

  var isAvailable: Bool {
    switch self {
    case .available:
      true
    case .disabledInPreferences, .requiresSingleSelection, .requiresSelection:
      false
    }
  }

  var helpText: String {
    switch self {
    case .available:
      "Show changed files"
    case .disabledInPreferences:
      "Files are turned off in Reviews settings"
    case .requiresSingleSelection:
      "Select a single pull request to review files"
    case .requiresSelection:
      "Select a pull request to review files"
    }
  }

  var unavailableSummary: String? {
    switch self {
    case .available:
      nil
    case .disabledInPreferences:
      "Enable in Reviews settings"
    case .requiresSingleSelection:
      "Select one pull request"
    case .requiresSelection:
      "Select a pull request"
    }
  }

  var systemImage: String {
    switch self {
    case .available:
      "doc.on.doc"
    case .disabledInPreferences, .requiresSingleSelection, .requiresSelection:
      "doc"
    }
  }
}

struct DashboardReviewDetailModeSwitcher: View {
  @Binding var detailMode: DashboardReviewsDetailMode
  let filesAvailability: DashboardReviewsFilesModeAvailability

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
          helpText: filesAvailability.helpText,
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
    .accessibilityValue(
      mode == .files && !filesAvailability.isAvailable
        ? "Unavailable"
        : (isSelected ? "Selected" : "Not selected")
    )
    .accessibilityHint(helpText)
    .accessibilityIdentifier(accessibilityIdentifier)
    .help(helpText)
    .disabled(mode == .files && !filesAvailability.isAvailable)
  }
}

struct DashboardReviewDetailHeader<Actions: View>: View {
  let item: ReviewItem
  @Binding var detailMode: DashboardReviewsDetailMode
  let filesAvailability: DashboardReviewsFilesModeAvailability
  let jumpTargets: [DashboardReviewDetailSectionID]
  let onJumpTo: (String) -> Void
  @ViewBuilder let actionBar: () -> Actions

  @Environment(\.openURL)
  private var openURL

  private var pullRequestURL: URL? {
    URL(string: item.url)
  }

  private var authorProfileURL: URL? {
    URL(string: "https://github.com/\(item.authorLogin.dashboardReviewGitHubPathEncoded)")
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
            DashboardReviewInlineTitle(
              title: item.title,
              hidesSemanticPrefix: false,
              font: .system(.title2, design: .rounded, weight: .semibold),
              codeFont: .system(.title2, design: .monospaced, weight: .semibold)
            )
            .lineLimit(2)
            .truncationMode(.tail)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
          }
          .harnessPlainButtonStyle()
          .contextMenu {
            DashboardReviewCopyableLinkContextMenu(
              valueTitle: "Copy Title",
              value: item.title,
              urlTitle: "Copy Pull Request URL",
              openTitle: "Open Pull Request",
              destination: pullRequestURL
            )
          }
          .help("Open pull request on GitHub")
          .accessibilityHint("Opens the pull request on GitHub")

          HStack(spacing: HarnessMonitorTheme.spacingSM) {
            DashboardReviewDetailModeSwitcher(
              detailMode: $detailMode,
              filesAvailability: filesAvailability
            )
            jumpToMenu
          }
        }

        HStack(spacing: 0) {
          DashboardReviewMetadataLink(
            title: "\(item.repository)#\(item.number)",
            destination: pullRequestURL,
            helpText: "Open pull request on GitHub",
            accessibilityHint: "Opens the pull request on GitHub",
            copyValueTitle: "Copy Repository and Number",
            copyURLTitle: "Copy Pull Request URL",
            openDestinationTitle: "Open Pull Request",
            truncationMode: .middle
          )
          .layoutPriority(1)
          DashboardReviewMetadataSeparator()
          DashboardReviewMetadataLink(
            title: "@\(item.authorLogin)",
            destination: authorProfileURL,
            helpText: "Open author profile on GitHub",
            accessibilityHint: "Opens the author profile on GitHub",
            copyValueTitle: "Copy Author",
            copyURLTitle: "Copy Author URL",
            openDestinationTitle: "Open Author Profile",
            fixesHorizontalSize: true
          )
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .scaledFont(.callout)
        .foregroundStyle(HarnessMonitorTheme.secondaryInk)
      }

      actionBar()
      if item.requiresAttention {
        DashboardReviewAttentionSummary(item: item)
      } else {
        DashboardReviewStatusStrip(item: item)
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

private struct DashboardReviewMetadataSeparator: View {
  var body: some View {
    Text(" · ")
      .foregroundStyle(HarnessMonitorTheme.tertiaryInk.opacity(0.86))
      .fixedSize(horizontal: true, vertical: false)
  }
}

private struct DashboardReviewMetadataLink: View {
  let title: String
  let destination: URL?
  let helpText: String
  let accessibilityHint: String
  let copyValueTitle: String
  let copyURLTitle: String
  let openDestinationTitle: String
  var truncationMode: Text.TruncationMode = .tail
  var fixesHorizontalSize = false

  @Environment(\.openURL)
  private var openURL

  @State private var isHovering = false

  var body: some View {
    Button {
      guard let destination else { return }
      openURL(destination)
    } label: {
      Text(verbatim: title)
        .lineLimit(1)
        .truncationMode(truncationMode)
        .fixedSize(horizontal: fixesHorizontalSize, vertical: false)
        .foregroundStyle(foregroundColor)
    }
    .buttonStyle(DashboardReviewMetadataLinkButtonStyle(isHovering: isHovering))
    .contextMenu {
      DashboardReviewCopyableLinkContextMenu(
        valueTitle: copyValueTitle,
        value: title,
        urlTitle: copyURLTitle,
        openTitle: openDestinationTitle,
        destination: destination
      )
    }
    .help(helpText)
    .accessibilityLabel(title)
    .accessibilityHint(accessibilityHint)
    .onHover { hovering in
      updateHoverState(hovering)
    }
    .onDisappear {
      guard isHovering else { return }
      NSCursor.pop()
      isHovering = false
    }
  }

  private var foregroundColor: Color {
    guard destination != nil else {
      return HarnessMonitorTheme.tertiaryInk.opacity(0.86)
    }
    return isHovering
      ? HarnessMonitorTheme.tertiaryInk
      : HarnessMonitorTheme.tertiaryInk.opacity(0.86)
  }

  private func updateHoverState(_ hovering: Bool) {
    guard destination != nil, isHovering != hovering else { return }
    isHovering = hovering
    if hovering {
      NSCursor.pointingHand.push()
    } else {
      NSCursor.pop()
    }
  }
}

private struct DashboardReviewCopyableLinkContextMenu: View {
  let valueTitle: String, value: String
  let urlTitle: String, openTitle: String
  let destination: URL?

  @Environment(\.openURL)
  private var openURL

  var body: some View {
    Button(valueTitle) { HarnessMonitorClipboard.copy(value) }
    if let destination {
      Button(urlTitle) { HarnessMonitorClipboard.copy(destination.absoluteString) }
      Divider()
      Button(openTitle) { openURL(destination) }
    }
  }
}

private struct DashboardReviewMetadataLinkButtonStyle: ButtonStyle {
  let isHovering: Bool

  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .padding(.horizontal, 2)
      .padding(.vertical, 1)
      .contentShape(Rectangle())
      .background {
        RoundedRectangle(cornerRadius: 4, style: .continuous)
          .fill(
            HarnessMonitorTheme.secondaryInk.opacity(
              isHovering ? (configuration.isPressed ? 0.14 : 0.08) : 0
            )
          )
      }
      .opacity(configuration.isPressed ? 0.72 : 1)
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
          .foregroundStyle(HarnessMonitorTheme.secondaryInk)
          .accessibilityAddTraits(.isHeader)
        Divider().opacity(0.40)
      }
      content()
    }
    .frame(maxWidth: reviewsDetailMaxWidth, alignment: .leading)
    .padding(.vertical, HarnessMonitorTheme.spacingMD)
  }
}
