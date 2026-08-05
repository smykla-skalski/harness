import HarnessMonitorKit
import SwiftUI

extension OpenWindowAction {
  @MainActor
  public func openHarnessDashboardWindow() {
    openHarnessDashboardWindow(recordHistory: true)
  }

  @MainActor
  public func openHarnessDashboardWindow(recordHistory: Bool) {
    if recordHistory {
      GlobalWindowNavigationHistoryRegistry.current?.recordDashboardOpen()
    }
    self(id: HarnessMonitorWindowID.dashboard)
  }

  @MainActor
  public func openHarnessDashboardAgent(_ target: DashboardAgentNavigationTarget) {
    GlobalWindowNavigationHistoryRegistry.current?.requestDashboardAgent(target)
    openHarnessDashboardWindow(recordHistory: false)
  }

  @MainActor
  public func openHarnessDashboardTaskBoard(_ target: DashboardTaskBoardNavigationTarget) {
    GlobalWindowNavigationHistoryRegistry.current?.requestDashboardTaskBoard(target)
    openHarnessDashboardWindow(recordHistory: false)
  }

  @MainActor
  public func openHarnessDashboardAudit(_ target: DashboardAuditNavigationTarget) {
    GlobalWindowNavigationHistoryRegistry.current?.requestDashboardAudit(target)
    openHarnessDashboardWindow(recordHistory: false)
  }

  @MainActor
  public func openHarnessDashboardDecision(decisionID: String) {
    openHarnessDashboardAgent(.decision(decisionID: decisionID))
  }
}
