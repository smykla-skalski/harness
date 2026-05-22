import HarnessMonitorKit
import SwiftUI

extension DashboardDependenciesRouteView {
  @ViewBuilder
  var batchConfirmationActions: some View {
    if let confirmation = routePendingBatchConfirmation {
      Button(confirmation.confirmTitle, role: .destructive) {
        confirmBatchAction(confirmation)
      }
      Button("Cancel", role: .cancel) {
        routePendingBatchConfirmation = nil
      }
    }
  }

  @ViewBuilder
  var batchConfirmationMessage: some View {
    if let confirmation = routePendingBatchConfirmation {
      Text(confirmation.message)
    }
  }

  func requestMerge(items: [DependencyUpdateItem]) {
    guard items.count > 1 else {
      trackInFlight(Task { await merge(items: items) })
      return
    }
    routePendingBatchConfirmation = .merge(
      items: items,
      mergeMethod: normalizedPreferences.mergeMethod
    )
  }

  func requestAuto(items: [DependencyUpdateItem]) {
    guard items.count > 1 else {
      trackInFlight(Task { await auto(items: items) })
      return
    }
    routePendingBatchConfirmation = .auto(
      items: items,
      mergeMethod: normalizedPreferences.mergeMethod
    )
  }

  func confirmBatchAction(_ confirmation: DashboardDependencyBatchConfirmation) {
    routePendingBatchConfirmation = nil
    let items = liveItems(for: confirmation.pullRequestIDs)
    switch confirmation.action {
    case .merge:
      trackInFlight(Task { await merge(items: items) })
    case .auto:
      trackInFlight(Task { await auto(items: items) })
    }
  }

  private func liveItems(for pullRequestIDs: [String]) -> [DependencyUpdateItem] {
    let byID = Dictionary(uniqueKeysWithValues: routeResponse.items.map { ($0.pullRequestID, $0) })
    return pullRequestIDs.compactMap { byID[$0] }
  }
}
