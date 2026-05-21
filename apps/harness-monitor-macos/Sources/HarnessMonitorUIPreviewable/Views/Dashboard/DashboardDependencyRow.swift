import HarnessMonitorKit
import SwiftUI

struct DashboardDependencyRow: View {
  let item: DependencyUpdateItem
  let showsRepository: Bool
  let isRefreshing: Bool
  let updatedLabel: String

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
  }
}
