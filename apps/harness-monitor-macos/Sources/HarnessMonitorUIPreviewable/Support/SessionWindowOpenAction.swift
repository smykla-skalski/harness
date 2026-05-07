import HarnessMonitorKit
import SwiftUI

extension OpenWindowAction {
  public func openHarnessSessionWindow(sessionID: String?) {
    guard let sessionID, !sessionID.isEmpty else {
      self(id: HarnessMonitorWindowID.main)
      return
    }
    self(
      id: HarnessMonitorWindowID.session,
      value: SessionWindowToken(sessionID: sessionID)
    )
  }

  public func openHarnessDecisionSession(
    decisionID: String,
    store: HarnessMonitorStore
  ) {
    let sessionID =
      store.supervisorOpenDecisions.first { $0.id == decisionID }?.sessionID
      ?? store.selectedSessionID
    openHarnessSessionWindow(sessionID: sessionID)
  }
}
