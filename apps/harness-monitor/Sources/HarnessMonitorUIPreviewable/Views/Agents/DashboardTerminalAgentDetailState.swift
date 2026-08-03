import Foundation
import HarnessMonitorKit
import Observation

struct DashboardTerminalActionToken: Equatable, Sendable {
  let id = UUID()
  let title: String
}

@MainActor
@Observable
final class DashboardTerminalAgentDetailState {
  private(set) var detail: DashboardTerminalAgentDetail?
  private(set) var isLoading = false
  private(set) var activeAction: String?
  private(set) var membershipRemoved = false
  var input = ""
  private var representedAgentID: String?
  private var activeToken: DashboardTerminalActionToken?
  private var loadInFlight = false
  private var generation: UInt64 = 0

  init(detail: DashboardTerminalAgentDetail? = nil, agentID: String? = nil) {
    self.detail = detail
    representedAgentID = agentID
  }

  func represents(agentID: String) -> Bool {
    representedAgentID == agentID
  }

  func beginLoad(agentID: String) -> UInt64? {
    if representedAgentID != agentID {
      detail = nil
      input = ""
      activeAction = nil
      activeToken = nil
      membershipRemoved = false
      representedAgentID = agentID
      loadInFlight = false
    } else if activeAction != nil || loadInFlight {
      return nil
    }
    generation &+= 1
    loadInFlight = true
    isLoading = detail == nil
    return generation
  }

  func finishLoad(_ detail: DashboardTerminalAgentDetail, generation expected: UInt64) {
    guard generation == expected else { return }
    if detail.isMember == nil, let priorMembership = self.detail?.isMember {
      self.detail = DashboardTerminalAgentDetail(
        snapshot: detail.snapshot,
        isMember: priorMembership,
        issues: mergedIssues(for: detail),
        refreshedAt: detail.refreshedAt
      )
    } else if detail.isMember == nil {
      self.detail = DashboardTerminalAgentDetail(
        snapshot: detail.snapshot,
        issues: mergedIssues(for: detail),
        refreshedAt: detail.refreshedAt
      )
    } else {
      self.detail = detail
    }
    loadInFlight = false
    isLoading = false
  }

  private func mergedIssues(for detail: DashboardTerminalAgentDetail) -> [String] {
    let membershipIssues =
      self.detail?.issues.filter {
        $0.hasPrefix("Membership unavailable:")
      } ?? []
    return (detail.issues + membershipIssues).reduce(into: []) { issues, issue in
      if !issues.contains(issue) { issues.append(issue) }
    }
  }

  func beginAction(_ title: String) -> DashboardTerminalActionToken? {
    guard activeAction == nil else { return nil }
    generation &+= 1
    loadInFlight = false
    isLoading = false
    let token = DashboardTerminalActionToken(title: title)
    activeAction = title
    activeToken = token
    return token
  }

  func finishAction(_ token: DashboardTerminalActionToken, snapshot: AgentTuiSnapshot?) {
    guard activeToken == token else { return }
    activeAction = nil
    activeToken = nil
    guard let snapshot else { return }
    detail = DashboardTerminalAgentDetail(
      snapshot: snapshot,
      isMember: detail?.isMember,
      issues: detail?.issues ?? []
    )
  }

  func finishInput(_ token: DashboardTerminalActionToken, snapshot: AgentTuiSnapshot?) {
    guard activeToken == token else { return }
    finishAction(token, snapshot: snapshot)
    if snapshot != nil { input = "" }
  }

  func finishRemoval(_ token: DashboardTerminalActionToken, succeeded: Bool) {
    guard activeToken == token else { return }
    activeAction = nil
    activeToken = nil
    membershipRemoved = succeeded
  }
}
