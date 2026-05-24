import HarnessMonitorKit
import SwiftUI

/// Compact control strip rendered above the Reviews list.
///
/// Layout strategy (top-to-bottom):
///
/// 1. **Scope** — the "Needs Me" toggle stands alone as a scope chip. It
///    visually anchors *which* PRs the list is showing the user, separately
///    from how those PRs are filtered/sorted/grouped. Rendered with the same
///    `harnessActionButtonStyle` family as the rest of the control surface
///    so it reads as a button instead of a hyperlink.
/// 2. **Refine** — Filter, Sort, and Group sit in a single wrap row using
///    icon-led menu labels. The menu buttons drop their leading "Filter: "
///    style prefix so each control fits in ~120 px and the three usually
///    stay on one line in the dashboard pane. Wrap layout still kicks in
///    when the pane is very narrow.
/// 3. **More** — the ellipsis menu carries low-frequency actions and the
///    "Dependencies only" toggle.
struct DashboardReviewsControlStrip: View {
  @Binding var filterModeRaw: String
  @Binding var sortModeRaw: String
  @Binding var groupModeRaw: String
  @Binding var needsMeOn: Bool
  @Binding var dependenciesOnlyOn: Bool
  let needsMeCount: Int
  let syncHealth: DashboardReviewsSyncHealth
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
      needsMeChip
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
        .fixedSize(horizontal: true, vertical: true)
    }
  }

  /// Renders the scope as an explicit on/off chip rather than a tinted toggle
  /// button. The on-state uses a filled checkmark glyph plus an accent tint
  /// so the chip reads as a *selected segment*, not as a hyperlink — the
  /// previous styling collided with link affordance in dense pickers.
  private var needsMeChip: some View {
    Button(action: { needsMeOn.toggle() }) {
      HStack(spacing: HarnessMonitorTheme.spacingXS) {
        Image(systemName: needsMeOn ? "person.crop.circle.fill.badge.checkmark" : "person.crop.circle")
          .imageScale(.medium)
          .symbolRenderingMode(.hierarchical)
        Text("Needs Me")
        if needsMeCount > 0 {
          Text(verbatim: "\(needsMeCount)")
            .monospacedDigit()
            .padding(.horizontal, 6)
            .padding(.vertical, 1)
            .background(needsMeCountBackground)
        }
      }
    }
    .harnessActionButtonStyle(
      variant: .bordered,
      tint: needsMeOn ? HarnessMonitorTheme.accent : .secondary
    )
    .accessibilityIdentifier(HarnessMonitorAccessibility.dashboardReviewsNeedsMeToggle)
    .accessibilityLabel("Filter to pull requests that need your attention")
    .accessibilityValue(needsMeOn ? "On" : "Off")
    .help(
      needsMeOn
        ? "Showing only PRs that need your attention. Click to show all."
        : "Click to show only PRs that need your attention."
    )
  }

  private var needsMeCountBackground: some View {
    RoundedRectangle(cornerRadius: HarnessMonitorTheme.pillCornerRadius, style: .continuous)
      .fill((needsMeOn ? HarnessMonitorTheme.accent : HarnessMonitorTheme.secondaryInk).opacity(0.18))
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
      HStack(spacing: HarnessMonitorTheme.spacingXS) {
        Image(systemName: systemImage)
          .imageScale(.medium)
          .symbolRenderingMode(.hierarchical)
        Text(currentTitle)
          .lineLimit(1)
          .truncationMode(.tail)
        Image(systemName: "chevron.down")
          .imageScale(.small)
          .foregroundStyle(HarnessMonitorTheme.secondaryInk)
      }
    }
    .menuStyle(.button)
    .menuIndicator(.hidden)
    .harnessActionButtonStyle(variant: .bordered, tint: .secondary)
    .accessibilityIdentifier(accessibilityIdentifier)
    .help(help)
  }

  private var actionsMenu: some View {
    Menu {
      Toggle("Dependencies only", isOn: $dependenciesOnlyOn)
        .accessibilityIdentifier(HarnessMonitorAccessibility.dashboardReviewsCategoryToggle)
        .accessibilityLabel("Show only dependency bot pull requests")

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
        .frame(width: 18, height: 18)
        .frame(width: 28, height: 28)
        .accessibilityLabel("More review actions")
    }
    .menuStyle(.button)
    .menuIndicator(.hidden)
    .harnessActionButtonStyle(variant: .bordered, tint: .secondary)
    .accessibilityLabel("More review actions")
  }
}
