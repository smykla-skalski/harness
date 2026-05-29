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
          .disabled(pullRequestURL == nil)
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
            truncationMode: .middle
          )
          .layoutPriority(1)
          DashboardReviewMetadataSeparator()
          DashboardReviewMetadataLink(
            title: "@\(item.authorLogin)",
            destination: authorProfileURL,
            helpText: "Open author profile on GitHub",
            accessibilityHint: "Opens the author profile on GitHub",
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
    .disabled(destination == nil)
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

private enum DashboardReviewOverviewSignalKind: String, Identifiable {
  case files
  case checks
  case reviews

  var id: String { rawValue }
}

private struct DashboardReviewOverviewSignal: Identifiable {
  let kind: DashboardReviewOverviewSignalKind
  let title: String
  let subtitle: String
  let systemImage: String
  let tint: Color
  let helpText: String
  let isEnabled: Bool

  var id: DashboardReviewOverviewSignalKind { kind }
}

struct DashboardReviewOverviewSignalStrip: View {
  let item: ReviewItem
  let filesAvailability: DashboardReviewsFilesModeAvailability
  @Binding var detailMode: DashboardReviewsDetailMode
  @Binding var showsSecondaryDetails: Bool
  @Binding var jumpTarget: String?

  var body: some View {
    ViewThatFits(in: .horizontal) {
      HStack(alignment: .top, spacing: HarnessMonitorTheme.spacingSM) {
        ForEach(signals) { signal in
          signalButton(signal)
        }
      }
      VStack(alignment: .leading, spacing: HarnessMonitorTheme.spacingSM) {
        ForEach(signals) { signal in
          signalButton(signal)
        }
      }
    }
  }

  private var signals: [DashboardReviewOverviewSignal] {
    [filesSignal, checksSignal, reviewsSignal]
  }

  private var filesSignal: DashboardReviewOverviewSignal {
    let subtitle = filesAvailability.unavailableSummary ?? lineChangeSummary
    return DashboardReviewOverviewSignal(
      kind: .files,
      title: "Files",
      subtitle: subtitle,
      systemImage: filesAvailability.systemImage,
      tint:
        filesAvailability.isAvailable
        ? HarnessMonitorTheme.accent
        : HarnessMonitorTheme.secondaryInk,
      helpText:
        filesAvailability.isAvailable
        ? "Open Files. Code diffs stay on demand to preserve GitHub budget."
        : filesAvailability.helpText,
      isEnabled: filesAvailability.isAvailable
    )
  }

  private var checksSignal: DashboardReviewOverviewSignal {
    DashboardReviewOverviewSignal(
      kind: .checks,
      title: "Checks",
      subtitle: checksSummary,
      systemImage: checksSystemImage,
      tint: checksTint,
      helpText: "Open more details to inspect checks and rerun actions.",
      isEnabled: true
    )
  }

  private var reviewsSignal: DashboardReviewOverviewSignal {
    DashboardReviewOverviewSignal(
      kind: .reviews,
      title: "Reviews",
      subtitle: reviewsSummary,
      systemImage: reviewsSystemImage,
      tint: reviewsTint,
      helpText: "Open more details to inspect reviewer state and comments.",
      isEnabled: true
    )
  }

  private var lineChangeSummary: String {
    if item.additions == 0, item.deletions == 0 {
      return "No line changes"
    }
    return "+\(item.additions) -\(item.deletions) lines"
  }

  private var checksSummary: String {
    let attentionCount = item.checks.count { $0.requiresAttention }
    switch item.checkStatus {
    case .failure:
      if attentionCount > 0 {
        return "\(attentionCount) need attention"
      }
      return item.checks.isEmpty ? "Checks failed" : "\(item.checks.count) checks failed"
    case .pending:
      return item.checks.isEmpty ? "Checks are running" : "\(item.checks.count) running"
    case .success:
      return item.checks.isEmpty ? "No checks reported" : "\(item.checks.count) passing"
    case .none:
      return "No checks reported"
    case .unknown:
      return item.checks.isEmpty ? "Checks unavailable" : "\(item.checks.count) checks recorded"
    }
  }

  private var checksSystemImage: String {
    switch item.checkStatus {
    case .failure:
      "exclamationmark.triangle"
    case .pending:
      "clock"
    case .success:
      "checkmark.circle"
    case .none, .unknown:
      "checklist"
    }
  }

  private var checksTint: Color {
    switch item.checkStatus {
    case .failure:
      HarnessMonitorTheme.danger
    case .pending:
      HarnessMonitorTheme.caution
    case .success:
      HarnessMonitorTheme.success
    case .none, .unknown:
      HarnessMonitorTheme.secondaryInk
    }
  }

  private var reviewsSummary: String {
    let approvals = item.reviews.count { $0.state == .approved }
    let changesRequested = item.reviews.count { $0.state == .changesRequested }
    switch (approvals, changesRequested, item.reviews.count) {
    case (_, let changesRequested, _) where changesRequested > 0 && approvals > 0:
      let changeNoun = changesRequested == 1 ? "change request" : "change requests"
      let approvalNoun = approvals == 1 ? "approval" : "approvals"
      return "\(approvals) \(approvalNoun), \(changesRequested) \(changeNoun)"
    case (_, let changesRequested, _) where changesRequested > 0:
      let changeNoun = changesRequested == 1 ? "change request" : "change requests"
      return "\(changesRequested) \(changeNoun)"
    case (let approvals, _, _) where approvals > 0:
      let approvalNoun = approvals == 1 ? "approval" : "approvals"
      return "\(approvals) \(approvalNoun)"
    case (_, _, 0):
      return "No reviews yet"
    default:
      let reviewCount = item.reviews.count
      let reviewNoun = reviewCount == 1 ? "review" : "reviews"
      return "\(reviewCount) \(reviewNoun) recorded"
    }
  }

  private var reviewsSystemImage: String {
    if item.reviews.contains(where: { $0.state == .changesRequested }) {
      return "arrow.uturn.backward.circle"
    }
    if item.reviews.contains(where: { $0.state == .approved }) {
      return "checkmark.seal"
    }
    return "person.2"
  }

  private var reviewsTint: Color {
    if item.reviews.contains(where: { $0.state == .changesRequested }) {
      return HarnessMonitorTheme.caution
    }
    if item.reviews.contains(where: { $0.state == .approved }) {
      return HarnessMonitorTheme.success
    }
    return HarnessMonitorTheme.secondaryInk
  }

  private func signalButton(_ signal: DashboardReviewOverviewSignal) -> some View {
    Button {
      switch signal.kind {
      case .files:
        detailMode = .files
      case .checks, .reviews:
        showsSecondaryDetails = true
        jumpTarget = DashboardReviewDetailSectionID.moreDetails.rawValue
      }
    } label: {
      VStack(alignment: .leading, spacing: HarnessMonitorTheme.spacingXS) {
        Label(signal.title, systemImage: signal.systemImage)
          .scaledFont(.caption.weight(.semibold))
          .foregroundStyle(HarnessMonitorTheme.ink)
          .lineLimit(1)
        Text(signal.subtitle)
          .scaledFont(.callout.weight(.semibold))
          .foregroundStyle(HarnessMonitorTheme.secondaryInk)
          .lineLimit(2)
          .fixedSize(horizontal: false, vertical: true)
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      .padding(.horizontal, HarnessMonitorTheme.spacingMD)
      .padding(.vertical, HarnessMonitorTheme.spacingSM)
      .frame(minHeight: 44, alignment: .leading)
    }
    .harnessInteractiveCardButtonStyle(
      tint: signal.tint,
      respondsToHover: true
    )
    .disabled(!signal.isEnabled)
    .accessibilityLabel(signal.title)
    .accessibilityValue(signal.subtitle)
    .accessibilityHint(signal.helpText)
    .help(signal.helpText)
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
