import SwiftUI

extension DashboardDependenciesRouteView {
  func trackInFlight(_ task: Task<Void, Never>) {
    inFlightTasks.append(task)
  }

  func cancelAllInFlightTasks() {
    inFlightTasks.forEach { $0.cancel() }
    inFlightTasks.removeAll()
  }
}
