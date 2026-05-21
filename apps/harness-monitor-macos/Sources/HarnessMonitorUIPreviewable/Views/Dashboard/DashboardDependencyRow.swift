import HarnessMonitorKit
import SwiftUI

struct DashboardDependencyRow: View {
  let item: DependencyUpdateItem
  let showsRepository: Bool
  let isRefreshing: Bool
  let updatedLabel: String
  let availableLabels: [DependencyUpdateRepositoryLabel]
  let frequentNames: [String]
  let showsDescriptions: Bool
  let canApprove: Bool
  let canMerge: Bool
  let hasRerunnableChecks: Bool
  let canRunAutoMode: Bool
  let onOpen: () -> Void
  let onCopyLink: () -> Void
  let onApprove: () -> Void
  let onMerge: () -> Void
  let onRerunChecks: () -> Void
  let onSelectLabel: (String) -> Void
  let onCustomLabel: () -> Void
  let onAuto: () -> Void
  let onFixCI: () -> Void

  var body: some View {
    DashboardDependencyListRow(
      item: item,
      showsRepository: showsRepository,
      isRefreshing: isRefreshing,
      updatedLabel: updatedLabel
    )
    .tag(item.pullRequestID)
    .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 0))
    .listRowSeparator(.hidden)
    .contextMenu {
      Button("Open Pull Request", action: onOpen)
      Button("Copy Link", action: onCopyLink)
      Divider()
      Button("Approve", action: onApprove)
        .disabled(!canApprove)
      Button("Merge", action: onMerge)
        .disabled(!canMerge)
      Button("Rerun Checks", action: onRerunChecks)
        .disabled(!hasRerunnableChecks)
      DashboardDependenciesLabelPickerMenu(
        title: "Add Label",
        labels: availableLabels,
        frequentNames: frequentNames,
        showsDescriptions: showsDescriptions,
        onSelect: onSelectLabel,
        onCustom: onCustomLabel
      )
      Button("Auto", action: onAuto)
        .disabled(!canRunAutoMode)
      if item.canStartFixCI {
        Button("Fix CI", action: onFixCI)
      }
    }
  }
}
