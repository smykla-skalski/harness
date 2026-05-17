import Foundation

extension HarnessMonitorStore {
  public var selectedSessionSession: SessionSummary? {
    contentUI.sessionDetail.selectedSessionSession
  }

  public var selectedSessionAgents: [AgentRegistration] {
    contentUI.sessionDetail.selectedSessionAgents
  }

  public var selectedSessionTasks: [WorkItem] {
    contentUI.sessionDetail.selectedSessionTasks
  }

  public var selectedSessionSignals: [SessionSignalRecord] {
    contentUI.sessionDetail.selectedSessionSignals
  }

  public var selectedSessionSignalsRevision: UInt64 {
    contentUI.sessionDetail.selectedSessionSignalsRevision
  }

  public var presentedTimelineRevision: UInt64 {
    contentUI.sessionDetail.presentedTimelineRevision
  }

  public var presentedTimelineWindowRevision: UInt64 {
    contentUI.sessionDetail.presentedTimelineWindowRevision
  }

  public var selectedSessionObserver: ObserverSummary? {
    contentUI.sessionDetail.selectedSessionObserver
  }

  public var selectedSessionAgentActivity: [AgentToolActivitySummary] {
    contentUI.sessionDetail.selectedSessionAgentActivity
  }
}
