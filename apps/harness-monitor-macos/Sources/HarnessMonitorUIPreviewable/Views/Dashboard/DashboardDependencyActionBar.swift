import HarnessMonitorKit
import SwiftUI

struct DashboardDependencyActionBar: View {
  let items: [DependencyUpdateItem]
  let availableLabels: [DependencyUpdateRepositoryLabel]
  let frequentNames: [String]
  let showsDescriptions: Bool
  let onApprove: () -> Void
  let onMerge: () -> Void
  let onRerunChecks: () -> Void
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
      title: "Approve", systemImage: "checkmark.seal", prominence: .primary, action: onApprove
    )
    .disabled(!items.contains { $0.canAttemptManualApproval })

    DashboardDependencyActionButton(
      title: "Merge", systemImage: "arrow.triangle.merge", prominence: .success, action: onMerge
    )
    .disabled(!items.contains { $0.canAttemptManualMerge })

    DashboardDependencyActionButton(
      title: "Rerun Checks",
      systemImage: "arrow.clockwise.circle",
      prominence: .secondary,
      action: onRerunChecks
    )
    .disabled(!items.contains { $0.hasRerunnableChecks })

    DashboardDependenciesLabelPickerActionMenu(
      labels: availableLabels,
      frequentNames: frequentNames,
      showsDescriptions: showsDescriptions,
      onSelect: onSelectLabel,
      onCustom: onCustomLabel
    )
    .disabled(items.isEmpty)

    DashboardDependencyActionButton(
      title: "Copy Approval Links",
      systemImage: "doc.on.doc",
      prominence: .secondary,
      action: onCopyApprovalLinks
    )

    if items.count == 1, let item = items.first {
      DashboardDependencyActionButton(
        title: "Auto", systemImage: "bolt", prominence: .utility, action: onAuto
      )
      .disabled(!item.canRunAutoMode)
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
        title: "Auto", systemImage: "bolt", prominence: .utility, action: onAuto
      )
      .disabled(!items.contains { $0.canRunAutoMode })
    }
  }
}
