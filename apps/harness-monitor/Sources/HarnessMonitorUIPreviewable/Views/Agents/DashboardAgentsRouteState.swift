import Foundation
import HarnessMonitorKit
import Observation

enum DashboardAgentsContentState: Equatable {
  case firstRun
  case loading
  case empty
  case content
}

struct DashboardAgentBrowserViewState: Equatable, Sendable {
  var agents: [DashboardAgentSummary] = []
  var isLoading = false
  var hasAttemptedLoad = false
  var source: DashboardAgentDataSource?
  var issue: DashboardAgentLoadIssue?
  var cachedAt: Date?
  var refreshedAt: Date?

  var contentState: DashboardAgentsContentState {
    if !agents.isEmpty { return .content }
    if isLoading { return .loading }
    return hasAttemptedLoad ? .empty : .firstRun
  }

  func contentState(hasDecisionDestinations: Bool) -> DashboardAgentsContentState {
    hasDecisionDestinations ? .content : contentState
  }

  var groups: [DashboardAgentWorkspaceGroup] {
    DashboardAgentWorkspaceGroup.make(from: agents)
  }

  var presentsAsFullWidthState: Bool {
    switch contentState {
    case .firstRun, .empty:
      true
    case .loading, .content:
      false
    }
  }

  func presentsAsFullWidthState(hasDecisionDestinations: Bool) -> Bool {
    if hasDecisionDestinations { return false }
    return presentsAsFullWidthState
  }
}

@MainActor
@Observable
final class DashboardAgentsRouteState {
  private(set) var viewState: DashboardAgentBrowserViewState
  private var generation: UInt64 = 0

  init(viewState: DashboardAgentBrowserViewState = DashboardAgentBrowserViewState()) {
    self.viewState = viewState
  }

  func beginLoad(force: Bool) -> UInt64? {
    guard force || !viewState.isLoading else { return nil }
    generation &+= 1
    viewState.isLoading = true
    viewState.hasAttemptedLoad = true
    viewState.issue = nil
    return generation
  }

  func adoptCache(
    _ snapshot: DashboardAgentCacheSnapshot,
    generation expectedGeneration: UInt64
  ) {
    guard generation == expectedGeneration else { return }
    viewState.cachedAt = snapshot.cachedAt
    guard !snapshot.agents.isEmpty, viewState.source == nil || viewState.source == .cache else {
      return
    }
    viewState.agents = snapshot.agents
    viewState.source = .cache
  }

  func finishLoad(
    _ result: DashboardAgentRefreshResult,
    generation expectedGeneration: UInt64
  ) {
    guard generation == expectedGeneration else { return }
    viewState.agents = result.agents
    viewState.source = result.source
    viewState.issue = result.issue
    viewState.refreshedAt = result.refreshedAt
    viewState.isLoading = false
    viewState.hasAttemptedLoad = true
  }
}

enum DashboardAgentSelectionDefaults {
  static let storageKey = "dashboard.agents.selection"
}
