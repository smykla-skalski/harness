import HarnessMonitorKit
import SwiftUI

let reviewsDetailMaxWidth: CGFloat = 1_180

extension DashboardReviewsRouteView {
  func errorState(message: String) -> some View {
    ContentUnavailableView {
      Label("Reviews unavailable", systemImage: "exclamationmark.triangle")
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
