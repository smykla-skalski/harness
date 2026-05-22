import HarnessMonitorKit
import SwiftUI

struct DashboardDependenciesControlStrip: View {
  @Binding var filterModeRaw: String
  @Binding var sortModeRaw: String
  @Binding var groupModeRaw: String
  let needsMeCount: Int
  let onRefresh: () -> Void
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

  private var isNeedsMeActive: Bool {
    filterModeRaw == DashboardDependenciesFilterMode.blocked.rawValue
  }

  private var needsMeChip: some View {
    Toggle(isOn: needsMeBinding) {
      if needsMeCount > 0 {
        Text("Needs Me (\(needsMeCount))")
      } else {
        Text("Needs Me")
      }
    }
    .toggleStyle(.button)
    .controlSize(.regular)
    .accessibilityLabel("Filter to pull requests that need your attention")
  }

  private var needsMeBinding: Binding<Bool> {
    Binding(
      get: { isNeedsMeActive },
      set: { newValue in
        filterModeRaw =
          newValue
          ? DashboardDependenciesFilterMode.blocked.rawValue
          : DashboardDependenciesFilterMode.all.rawValue
      }
    )
  }

  private var filterPicker: some View {
    Picker("Filter", selection: $filterModeRaw) {
      ForEach(DashboardDependenciesFilterMode.pickerCases) { mode in
        Text(mode.title).tag(mode.rawValue)
      }
    }
    .pickerStyle(.menu)
    .accessibilityIdentifier(HarnessMonitorAccessibility.dashboardDependenciesSelectionStatus)
  }

  private var sortPicker: some View {
    Picker("Sort", selection: $sortModeRaw) {
      ForEach(DashboardDependenciesSortMode.pickerCases) { mode in
        Text(mode.title).tag(mode.rawValue)
      }
    }
    .pickerStyle(.menu)
  }

  private var groupPicker: some View {
    Picker("Group", selection: $groupModeRaw) {
      ForEach(DashboardDependenciesGroupMode.pickerCases) { mode in
        Text(mode.title).tag(mode.rawValue)
      }
    }
    .pickerStyle(.menu)
  }

  private var actionsMenu: some View {
    Menu {
      Button(action: onRefresh) {
        Label("Refresh", systemImage: "arrow.clockwise")
      }
      .accessibilityIdentifier(HarnessMonitorAccessibility.dashboardDependenciesRefreshButton)

      Divider()

      Button(action: onClearCache) {
        Label("Clear Cache", systemImage: "trash")
      }
    } label: {
      Image(systemName: "ellipsis.circle")
        .imageScale(.medium)
        .frame(width: 18, height: 18)
        .accessibilityLabel("More dependency actions")
    }
    .menuStyle(.button)
    .harnessActionButtonStyle(variant: .bordered, tint: .secondary)
    .accessibilityLabel("More dependency actions")
  }
}
