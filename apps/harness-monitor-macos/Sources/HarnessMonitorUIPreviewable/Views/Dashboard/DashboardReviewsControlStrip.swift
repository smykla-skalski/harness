import HarnessMonitorKit
import SwiftUI

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
      HStack(alignment: .top, spacing: HarnessMonitorTheme.spacingSM) {
        HarnessMonitorWrapLayout(
          spacing: HarnessMonitorTheme.spacingSM,
          lineSpacing: HarnessMonitorTheme.spacingSM
        ) {
          needsMeChip
          filterPicker
          sortPicker
          groupPicker
        }
        .frame(maxWidth: .infinity, alignment: .leading)

        actionsMenu
          .fixedSize(horizontal: true, vertical: true)
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  private var needsMeChip: some View {
    Toggle(isOn: $needsMeOn) {
      if needsMeCount > 0 {
        Text("Needs Me (\(needsMeCount))")
      } else {
        Text("Needs Me")
      }
    }
    .toggleStyle(.button)
    .controlSize(.regular)
    .accessibilityIdentifier(HarnessMonitorAccessibility.dashboardReviewsNeedsMeToggle)
    .accessibilityLabel("Filter to pull requests that need your attention")
  }

  // Legacy identifier `HarnessMonitorAccessibility.dashboardReviewsSelectionStatus`
  // is superseded by `dashboardReviewsFilterPicker`; the constant stays declared so
  // any older XCUITest binary still resolves it without crashing.
  private var filterPicker: some View {
    Picker("Filter", selection: $filterModeRaw) {
      ForEach(DashboardReviewsFilterMode.pickerCases) { mode in
        Text(mode.title).tag(mode.rawValue)
      }
    }
    .pickerStyle(.menu)
    .controlSize(.regular)
    .accessibilityIdentifier(HarnessMonitorAccessibility.dashboardReviewsFilterPicker)
  }

  private var sortPicker: some View {
    Picker("Sort", selection: $sortModeRaw) {
      ForEach(DashboardReviewsSortMode.pickerCases) { mode in
        Text(mode.title).tag(mode.rawValue)
      }
    }
    .pickerStyle(.menu)
    .controlSize(.regular)
    .accessibilityIdentifier(HarnessMonitorAccessibility.dashboardReviewsSortPicker)
  }

  private var groupPicker: some View {
    Picker("Group", selection: $groupModeRaw) {
      ForEach(DashboardReviewsGroupMode.pickerCases) { mode in
        Text(mode.title).tag(mode.rawValue)
      }
    }
    .pickerStyle(.menu)
    .controlSize(.regular)
    .accessibilityIdentifier(HarnessMonitorAccessibility.dashboardReviewsGroupPicker)
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
    .harnessActionButtonStyle(variant: .bordered, tint: .secondary)
    .accessibilityLabel("More review actions")
  }
}
