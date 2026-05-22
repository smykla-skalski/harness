import HarnessMonitorKit
import SwiftUI

struct DashboardDependencyActionBar: View {
  let items: [DependencyUpdateItem]
  let availableLabels: [DependencyUpdateRepositoryLabel]
  let frequentNames: [String]
  let showsDescriptions: Bool
  let isBusy: Bool
  let onApprove: () -> Void
  let onMerge: () -> Void
  let onRerunChecks: () -> Void
  let onRefresh: () -> Void
  let onSelectLabel: (String) -> Void
  let onCustomLabel: () -> Void
  let onCopyApprovalLinks: () -> Void
  let onAuto: () -> Void
  let onOpenItem: () -> Void
  let onFixCI: () -> Void

  var body: some View {
    HarnessMonitorGlassControlGroup(spacing: HarnessMonitorTheme.itemSpacing) {
      HarnessMonitorWrapLayout(
        spacing: HarnessMonitorTheme.itemSpacing,
        lineSpacing: HarnessMonitorTheme.itemSpacing
      ) {
        buttons
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  @ViewBuilder private var buttons: some View {
    DashboardDependencyActionButton(
      title: "Approve",
      systemImage: "checkmark.seal",
      prominence: .primary,
      helpText: DashboardDependenciesDisabledReason.approveReason(for: items),
      action: onApprove
    )
    .disabled(isBusy || !items.contains { $0.canAttemptManualApproval })

    DashboardDependencyActionButton(
      title: "Merge",
      systemImage: "arrow.triangle.merge",
      prominence: .success,
      helpText: DashboardDependenciesDisabledReason.mergeReason(for: items),
      action: onMerge
    )
    .disabled(isBusy || !items.contains { $0.canAttemptManualMerge })

    DashboardDependencyActionButton(
      title: "Rerun Checks",
      systemImage: "arrow.clockwise.circle",
      prominence: .secondary,
      helpText: DashboardDependenciesDisabledReason.rerunReason(for: items),
      action: onRerunChecks
    )
    .disabled(isBusy || !items.contains { $0.hasRerunnableChecks })
    .help(rerunChecksHelp)
    .accessibilityHint(rerunChecksHelp)

    DashboardDependencyActionButton(
      title: "Refresh",
      systemImage: "arrow.clockwise",
      prominence: .secondary,
      helpText: DashboardDependenciesDisabledReason.emptySelectionReason(for: items),
      action: onRefresh
    )
    .disabled(isBusy || items.isEmpty)
    .accessibilityIdentifier(
      HarnessMonitorAccessibility.dashboardDependenciesRefreshSelectedButton
    )

    DashboardDependenciesLabelPickerActionMenu(
      labels: availableLabels,
      frequentNames: frequentNames,
      showsDescriptions: showsDescriptions,
      onSelect: onSelectLabel,
      onCustom: onCustomLabel
    )
    .disabled(isBusy || items.isEmpty)

    DashboardDependencyActionButton(
      title: "Copy Approval Links",
      systemImage: "doc.on.doc",
      prominence: .secondary,
      action: onCopyApprovalLinks
    )

    if items.count == 1, let item = items.first {
      DashboardDependencyActionButton(
        title: "Auto",
        systemImage: "bolt",
        prominence: .utility,
        helpText: DashboardDependenciesDisabledReason.autoReason(for: items),
        action: onAuto
      )
      .disabled(isBusy || !item.canRunAutoMode)
      DashboardDependencyActionButton(
        title: "Open Pull Request", systemImage: "safari", prominence: .utility, action: onOpenItem
      )
      if item.canStartFixCI {
        DashboardDependencyActionButton(
          title: "Fix CI",
          systemImage: "wrench.and.screwdriver",
          prominence: .secondary,
          action: onFixCI
        )
        .accessibilityIdentifier(HarnessMonitorAccessibility.dashboardDependenciesFixCIButton)
      }
    } else {
      DashboardDependencyActionButton(
        title: "Auto",
        systemImage: "bolt",
        prominence: .utility,
        helpText: DashboardDependenciesDisabledReason.autoReason(for: items)
          ?? DashboardDependenciesDisabledReason.autoPreview(for: items),
        action: onAuto
      )
      .disabled(isBusy || !items.contains { $0.canRunAutoMode })
    }
  }

  private var rerunChecksHelp: String {
    if items.isEmpty {
      return "Select a dependency update to rerun failed checks."
    }
    if items.contains(where: { $0.hasRerunnableChecks }) {
      return "Rerun failed or timed-out GitHub check suites."
    }
    if items.count == 1, let reason = items.first?.rerunChecksUnavailableReason {
      return reason
    }
    return "No selected dependency update has rerunnable failed or timed-out checks."
  }
}
