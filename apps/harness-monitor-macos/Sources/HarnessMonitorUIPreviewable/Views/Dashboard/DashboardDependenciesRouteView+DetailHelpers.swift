import HarnessMonitorKit
import SwiftUI

let dependenciesDetailMaxWidth: CGFloat = 940

extension DashboardDependenciesRouteView {
  func errorState(message: String) -> some View {
    ContentUnavailableView {
      Label("Dependencies unavailable", systemImage: "exclamationmark.triangle")
    } description: {
      Text(message)
    } actions: {
      Button("Open Secrets") {
        openSettingsSection(.secrets)
      }
      Button("Open Sources Settings") {
        openSettingsSection(.repositories)
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }
}
