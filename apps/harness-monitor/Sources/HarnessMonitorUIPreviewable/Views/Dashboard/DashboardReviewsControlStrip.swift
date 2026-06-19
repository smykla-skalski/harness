import HarnessMonitorKit
import SwiftUI

/// Compact control strip rendered above the Reviews list.
///
/// Layout strategy (top-to-bottom):
///
/// 1. **Scope** — a single Inbox chip anchors the default grouping model while
///    lower-frequency scope filters move into the overflow menu.
/// 2. **Refine** — Filter, Sort, and Group sit in a single wrap row using
///    icon-led menu labels. The menu buttons drop their leading "Filter: "
///    style prefix so each control fits in ~120 px and the three usually
///    stay on one line in the dashboard pane. Wrap layout still kicks in
///    when the pane is very narrow.
/// 3. **More** — the ellipsis menu carries row-display toggles plus
///    low-frequency actions like retry / clear-cache.
struct DashboardReviewsControlStrip: View {
  @ScaledMetric(relativeTo: .body)
  private var refineIconTextSpacing = 10.0
  @ScaledMetric(relativeTo: .body)
  private var refineTrailingIconSpacing = 6.0
  @ScaledMetric(relativeTo: .body)
  private var compactMenuLabelHeight = 20.0

  @Binding var filterModeRaw: String
  @Binding var sortModeRaw: String
  @Binding var groupModeRaw: String
  @Binding var needsMeOn: Bool
  @Binding var dependenciesOnlyOn: Bool
  @Binding var showSnoozedOnly: Bool
  @Binding var showAvatarsInRows: Bool
  @Binding var showLabelsInRows: Bool
  @Binding var showLineCountersInRows: Bool
  @Binding var showApprovalCountsInRows: Bool
  @Binding var showTargetBranchInRows: Bool
  @Binding var showPullRequestNumberInRows: Bool
  @Binding var showPullRequestAgeInRows: Bool
  @Binding var wrapTitlesInRows: Bool
  @Binding var hideSemanticPrefixesInRowTitles: Bool
  let needsMeCount: Int
  let syncHealth: DashboardReviewsSyncHealth
  let onPastePullRequests: () -> Void
  let onRetryFailedRepositories: () -> Void
  let onRetryStaleRepositories: () -> Void
  let onClearCache: () -> Void

  var body: some View {
    HarnessMonitorGlassControlGroup(spacing: HarnessMonitorTheme.spacingSM) {
      VStack(alignment: .leading, spacing: HarnessMonitorTheme.spacingSM) {
        scopeRow
        refineRow
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  private var scopeRow: some View {
    HStack(alignment: .center, spacing: HarnessMonitorTheme.spacingSM) {
      inboxChip
      pastePullRequestsButton
      Spacer(minLength: HarnessMonitorTheme.spacingSM)
    }
  }

  private var refineRow: some View {
    HStack(alignment: .center, spacing: HarnessMonitorTheme.spacingSM) {
      HarnessMonitorWrapLayout(
        spacing: HarnessMonitorTheme.spacingSM,
        lineSpacing: HarnessMonitorTheme.spacingSM
      ) {
        filterMenu
        sortMenu
        groupMenu
      }
      .frame(maxWidth: .infinity, alignment: .leading)

      actionsMenu
        .fixedSize(horizontal: true, vertical: false)
    }
  }

  private var inboxChip: some View {
    let isInbox = groupModeRaw == DashboardReviewsGroupMode.smartInbox.rawValue
    return Button(
      action: {
        if isInbox {
          groupModeRaw = DashboardReviewsGroupMode.repository.rawValue
        } else {
          groupModeRaw = DashboardReviewsGroupMode.smartInbox.rawValue
        }
      },
      label: {
        HStack(spacing: HarnessMonitorTheme.spacingXS) {
          Image(systemName: isInbox ? "tray.circle.fill" : "tray.circle")
            .imageScale(.medium)
            .symbolRenderingMode(.hierarchical)
          Text("Inbox")
          if needsMeCount > 0 {
            needsMeCountBadge
          }
        }
      }
    )
    .harnessActionButtonStyle(
      variant: .bordered,
      tint: isInbox ? HarnessMonitorTheme.accent : .secondary
    )
    .accessibilityIdentifier("dashboardReviewsSmartInboxToggle")
    .accessibilityLabel("Group by inbox")
    .accessibilityValue(isInbox ? "On" : "Off")
    .help(
      isInbox
        ? "Inbox grouping is active. Click to group by repository."
        : "Click to activate the inbox grouping."
    )
  }

  @ScaledMetric(relativeTo: .caption2)
  private var needsMeBadgeDiameter = 18.0

  /// Circular requested-review count badge carried on the Inbox chip. The
  /// shape stays distinct from the repository count pills so glance readers do
  /// not confuse personal priority with per-section volume.
  private var needsMeCountBadge: some View {
    Text(verbatim: "\(needsMeCount)")
      .monospacedDigit()
      .scaledFont(.caption2.weight(.bold))
      .foregroundStyle(needsMeOn ? HarnessMonitorTheme.accent : HarnessMonitorTheme.secondaryInk)
      .frame(minWidth: needsMeBadgeDiameter, minHeight: needsMeBadgeDiameter)
      .padding(.horizontal, 4)
      .background(
        Capsule(style: .continuous)
          .fill(
            (needsMeOn ? HarnessMonitorTheme.accent : HarnessMonitorTheme.secondaryInk)
              .opacity(0.20)
          )
      )
  }

  private var pastePullRequestsButton: some View {
    Button(action: onPastePullRequests) {
      Label("Paste PRs", systemImage: "doc.on.clipboard")
    }
    .harnessActionButtonStyle(variant: .bordered, tint: .secondary)
    .accessibilityIdentifier(HarnessMonitorAccessibility.dashboardReviewsPastePRsButton)
    .accessibilityLabel("Paste pull request links")
    .help("Paste GitHub pull request links")
  }

  // Legacy identifier `HarnessMonitorAccessibility.dashboardReviewsSelectionStatus`
  // is superseded by `dashboardReviewsFilterPicker`; the constant stays declared so
  // any older XCUITest binary still resolves it without crashing.
  private var filterMenu: some View {
    refineMenu(
      systemImage: "line.3.horizontal.decrease.circle",
      currentTitle: DashboardReviewsFilterMode(rawValue: filterModeRaw)?.title ?? filterModeRaw,
      accessibilityIdentifier: HarnessMonitorAccessibility.dashboardReviewsFilterPicker,
      help: "Filter: \(DashboardReviewsFilterMode(rawValue: filterModeRaw)?.title ?? filterModeRaw)"
    ) {
      Picker("Filter", selection: $filterModeRaw) {
        ForEach(DashboardReviewsFilterMode.pickerCases) { mode in
          Text(mode.title).tag(mode.rawValue)
        }
      }
      .pickerStyle(.inline)
    }
  }

  private var sortMenu: some View {
    refineMenu(
      systemImage: "arrow.up.arrow.down.circle",
      currentTitle: DashboardReviewsSortMode(rawValue: sortModeRaw)?.title ?? sortModeRaw,
      accessibilityIdentifier: HarnessMonitorAccessibility.dashboardReviewsSortPicker,
      help: "Sort by \(DashboardReviewsSortMode(rawValue: sortModeRaw)?.title ?? sortModeRaw)"
    ) {
      Picker("Sort", selection: $sortModeRaw) {
        ForEach(DashboardReviewsSortMode.pickerCases) { mode in
          Text(mode.title).tag(mode.rawValue)
        }
      }
      .pickerStyle(.inline)
    }
  }

  private var groupMenu: some View {
    refineMenu(
      systemImage: "square.stack.3d.up",
      currentTitle: DashboardReviewsGroupMode(rawValue: groupModeRaw)?.title ?? groupModeRaw,
      accessibilityIdentifier: HarnessMonitorAccessibility.dashboardReviewsGroupPicker,
      help: "Group by \(DashboardReviewsGroupMode(rawValue: groupModeRaw)?.title ?? groupModeRaw)"
    ) {
      Picker("Group", selection: $groupModeRaw) {
        ForEach(DashboardReviewsGroupMode.pickerCases) { mode in
          Text(mode.title).tag(mode.rawValue)
        }
      }
      .pickerStyle(.inline)
    }
  }

  /// Shared shape for the Filter / Sort / Group menus.
  ///
  /// Each menu shows a leading icon (so the control type is obvious without
  /// reading a `Sort: ` prefix) plus the current value. The button is
  /// rendered with `harnessActionButtonStyle` so it visually matches the
  /// rest of the control surface and reads as a button rather than as a
  /// hyperlink.
  @ViewBuilder
  private func refineMenu(
    systemImage: String,
    currentTitle: String,
    accessibilityIdentifier: String,
    help: String,
    @ViewBuilder content: () -> some View
  ) -> some View {
    Menu {
      content()
    } label: {
      HStack(spacing: refineTrailingIconSpacing) {
        HStack(spacing: refineIconTextSpacing) {
          Image(systemName: systemImage)
            .imageScale(.medium)
            .symbolRenderingMode(.hierarchical)
          Text(currentTitle)
            .lineLimit(1)
            .truncationMode(.tail)
        }
        Image(systemName: "chevron.down")
          .imageScale(.small)
          .foregroundStyle(HarnessMonitorTheme.secondaryInk)
      }
      .frame(minHeight: compactMenuLabelHeight)
    }
    .menuStyle(.button)
    .menuIndicator(.hidden)
    .harnessActionButtonStyle(variant: .bordered, tint: .secondary)
    .accessibilityIdentifier(accessibilityIdentifier)
    .help(help)
  }

  private var actionsMenu: some View {
    Menu {
      Section("Scope") {
        Toggle("Needs me only", isOn: $needsMeOn)
          .accessibilityIdentifier(HarnessMonitorAccessibility.dashboardReviewsNeedsMeToggle)
          .accessibilityLabel("Show only pull requests where you are a requested reviewer")
        Toggle("Show snoozed only", isOn: $showSnoozedOnly)
          .accessibilityIdentifier("dashboardReviewsSnoozedToggle")
          .accessibilityLabel("Show only snoozed pull requests")
        Toggle("Dependencies only", isOn: $dependenciesOnlyOn)
          .accessibilityIdentifier(HarnessMonitorAccessibility.dashboardReviewsCategoryToggle)
          .accessibilityLabel("Show only dependency bot pull requests")
      }

      Divider()

      Section("Row display") {
        Toggle("Avatars", isOn: $showAvatarsInRows)
          .accessibilityIdentifier(HarnessMonitorAccessibility.dashboardReviewsShowRowAvatarsToggle)
          .accessibilityLabel("Show avatars in review rows")
        Toggle("Labels", isOn: $showLabelsInRows)
          .accessibilityIdentifier(HarnessMonitorAccessibility.dashboardReviewsShowRowLabelsToggle)
          .accessibilityLabel("Show labels in review rows")
        Toggle("+/- line counters", isOn: $showLineCountersInRows)
          .accessibilityIdentifier(
            HarnessMonitorAccessibility.dashboardReviewsLineCountersToggle
          )
          .accessibilityLabel("Show line counters in review rows")
        Toggle("Approval counts", isOn: $showApprovalCountsInRows)
          .accessibilityIdentifier(
            HarnessMonitorAccessibility.dashboardReviewsApprovalCountsToggle
          )
          .accessibilityLabel("Show approval counts in review rows")
        Toggle("Target branch", isOn: $showTargetBranchInRows)
          .accessibilityIdentifier(
            HarnessMonitorAccessibility.dashboardReviewsTargetBranchToggle
          )
          .accessibilityLabel("Show target branch for non-default pull requests in review rows")
        Toggle("PR number", isOn: $showPullRequestNumberInRows)
          .accessibilityIdentifier(
            HarnessMonitorAccessibility.dashboardReviewsPullRequestNumberToggle
          )
          .accessibilityLabel("Show pull request numbers in review rows")
        Toggle("PR age", isOn: $showPullRequestAgeInRows)
          .accessibilityIdentifier(
            HarnessMonitorAccessibility.dashboardReviewsPullRequestAgeToggle
          )
          .accessibilityLabel("Show pull request age in review rows")
        Toggle("Wrap titles", isOn: $wrapTitlesInRows)
          .accessibilityIdentifier(HarnessMonitorAccessibility.dashboardReviewsWrapRowTitlesToggle)
          .accessibilityLabel("Wrap review row titles")
        Toggle("Hide semantic prefixes", isOn: $hideSemanticPrefixesInRowTitles)
          .accessibilityIdentifier(
            HarnessMonitorAccessibility.dashboardReviewsSemanticPrefixesToggle
          )
          .accessibilityLabel("Hide semantic commit prefixes in review row titles")
      }

      Divider()

      if syncHealth.hasFailures {
        Button(action: onRetryFailedRepositories) {
          Label(
            "Retry Failed Repositories",
            systemImage: "exclamationmark.arrow.triangle.2.circlepath"
          )
        }
      }

      if syncHealth.hasStaleRepositories {
        Button(action: onRetryStaleRepositories) {
          Label("Retry Stale Repositories", systemImage: "clock.arrow.circlepath")
        }
      }

      if syncHealth.hasFailures || syncHealth.hasStaleRepositories {
        Divider()
      }

      Button(action: onClearCache) {
        Label("Clear Cache", systemImage: "trash")
      }
    } label: {
      Image(systemName: "ellipsis.circle")
        .imageScale(.medium)
        .symbolRenderingMode(.hierarchical)
        .frame(minHeight: compactMenuLabelHeight)
        .accessibilityLabel("More review actions")
    }
    .menuStyle(.button)
    .menuIndicator(.hidden)
    .harnessActionButtonStyle(variant: .bordered, tint: .secondary)
    .accessibilityLabel("More review actions")
  }
}
