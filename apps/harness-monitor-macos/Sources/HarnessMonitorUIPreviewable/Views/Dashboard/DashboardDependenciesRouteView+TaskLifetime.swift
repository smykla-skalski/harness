import SwiftUI

extension DashboardDependenciesRouteView {
  func trackInFlight(_ task: Task<Void, Never>) {
    var tasks = routeInFlightTasks
    tasks.append(task)
    routeInFlightTasks = tasks
  }

  func cancelAllInFlightTasks() {
    for task in routeInFlightTasks {
      task.cancel()
    }
    routeInFlightTasks = []
  }
}
