import HarnessMonitorKit
import SwiftUI

struct SessionAgentDetailSectionMetrics: Equatable {
  let sectionSpacing: CGFloat
  let sectionPadding: CGFloat
  let headerSpacing: CGFloat
  let terminalRowSpacing: CGFloat
  let terminalPadding: CGFloat
  let terminalCornerRadius: CGFloat
  let composerSpacing: CGFloat
  let keyStackSpacing: CGFloat
  let keyButtonWidth: CGFloat
  let controlButtonMinSize: CGFloat
  let composerMinHeight: CGFloat
  let composerMaxHeight: CGFloat

  init(fontScale: CGFloat) {
    let scale = SessionWindowFontScale.metricsScale(for: fontScale)
    sectionSpacing = 12 * min(scale, 1.35)
    sectionPadding = 20 * min(scale, 1.25)
    headerSpacing = 4 * min(scale, 1.4)
    terminalRowSpacing = 2 * min(scale, 1.35)
    terminalPadding = 12 * min(scale, 1.35)
    terminalCornerRadius = 8 * min(scale, 1.2)
    composerSpacing = 8 * min(scale, 1.35)
    keyStackSpacing = 6 * min(scale, 1.35)
    keyButtonWidth = max(22, 22 * min(scale, 1.3))
    controlButtonMinSize = scale >= 1.45 ? 44 : 0
    composerMinHeight = max(46, 46 * min(scale, 1.35))
    composerMaxHeight = max(120, 120 * min(scale, 1.2))
  }
}

struct SessionAgentOutputAnnouncementGate: Equatable {
  static let minimumInterval: TimeInterval = 0.1

  private var lastAnnouncementAt = Date.distantPast

  mutating func shouldAnnounce(output: String, now: Date = Date()) -> Bool {
    guard !output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
    guard now.timeIntervalSince(lastAnnouncementAt) >= Self.minimumInterval else { return false }
    lastAnnouncementAt = now
    return true
  }
}

enum SessionAgentComposerFocusPolicy {
  static func shouldPromoteComposerFocus(
    requestID: Int,
    isTuiActive: Bool
  ) -> Bool {
    requestID > 0 && isTuiActive
  }
}

extension SessionAgentDetailSection {
  func computeLatestOutput() -> String {
    let rows = tui?.screen.visibleRows(maxRows: 1) ?? []
    return rows.first?.text.trimmingCharacters(in: .whitespacesAndNewlines) ?? "No output"
  }

  var leaderID: String? {
    detail.session.leaderId
  }

  nonisolated static let noAvailableActionActorMessage =
    "No session actor is available yet. Wait for a leader or active agent to join, then try again."

  nonisolated static func draftCommandKey(sessionID: String, agentID: String) -> String {
    "harness.session.agentDraft.\(sessionID).\(agentID).command"
  }

  nonisolated static func draftMessageKey(sessionID: String, agentID: String) -> String {
    "harness.session.agentDraft.\(sessionID).\(agentID).message"
  }

  nonisolated static func draftActionHintKey(sessionID: String, agentID: String) -> String {
    "harness.session.agentDraft.\(sessionID).\(agentID).actionHint"
  }

  nonisolated static func transcriptEntries(
    agent: AgentRegistration,
    agentTimeline: [TimelineEntry],
    acpTranscript: [TimelineEntry]
  ) -> [TimelineEntry] {
    if agent.runtimeCapabilities.supportsNativeTranscript {
      return acpTranscript
    }
    return agentTimeline
  }

  nonisolated static func resolvedActionActorID(
    preferredActorID: String?,
    agents: [AgentRegistration],
    leaderID: String?
  ) -> String? {
    if let preferredActorID, agents.contains(where: { $0.agentId == preferredActorID }) {
      return preferredActorID
    }
    if let leaderID, agents.contains(where: { $0.agentId == leaderID }) {
      return leaderID
    }
    return agents.first(where: { $0.status == .active })?.agentId
  }

  nonisolated static func hasRealLeader(
    leaderID: String?,
    agents: [AgentRegistration]
  ) -> Bool {
    guard let leaderID else {
      return false
    }
    return agents.contains(where: { $0.agentId == leaderID })
  }
}
