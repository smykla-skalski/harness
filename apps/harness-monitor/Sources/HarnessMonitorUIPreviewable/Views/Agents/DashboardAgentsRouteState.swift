import Foundation
import HarnessMonitorKit
import Observation

enum DashboardAgentsContentState: Equatable {
  case firstRun
  case loading
  case empty
  case content
}

enum DashboardAgentsLoadPresentation: Equatable {
  case foreground
  case background
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
  @ObservationIgnored private(set) var lastCachedSnapshotAt: Date?
  @ObservationIgnored private(set) var lastCompletedRefreshAt: Date?
  private var generation: UInt64 = 0
  private var isLoadInFlight: Bool

  init(viewState: DashboardAgentBrowserViewState = DashboardAgentBrowserViewState()) {
    self.viewState = viewState
    lastCachedSnapshotAt = viewState.cachedAt
    lastCompletedRefreshAt = viewState.refreshedAt
    isLoadInFlight = viewState.isLoading
  }

  func beginLoad(
    force: Bool,
    presentation: DashboardAgentsLoadPresentation = .foreground
  ) -> UInt64? {
    guard force || !isLoadInFlight else { return nil }
    generation &+= 1
    isLoadInFlight = true
    if presentation == .foreground {
      viewState.isLoading = true
      viewState.hasAttemptedLoad = true
      viewState.issue = nil
    }
    return generation
  }

  func adoptCache(
    _ snapshot: DashboardAgentCacheSnapshot,
    generation expectedGeneration: UInt64
  ) {
    guard generation == expectedGeneration else { return }
    lastCachedSnapshotAt = snapshot.cachedAt
    guard !snapshot.agents.isEmpty, viewState.source == nil || viewState.source == .cache else {
      return
    }
    var next = viewState
    next.agents = snapshot.agents
    next.source = .cache
    guard next != viewState else { return }
    next.cachedAt = snapshot.cachedAt
    viewState = next
  }

  func finishLoad(
    _ result: DashboardAgentRefreshResult,
    generation expectedGeneration: UInt64
  ) {
    guard generation == expectedGeneration else { return }
    isLoadInFlight = false
    lastCompletedRefreshAt = result.refreshedAt
    var next = viewState
    next.agents = result.agents
    next.source = result.source
    next.issue = result.issue
    next.isLoading = false
    next.hasAttemptedLoad = true
    guard next != viewState else { return }
    next.refreshedAt = result.refreshedAt
    viewState = next
  }
}

enum DashboardAgentSelectionDefaults {
  static let storageKey = "dashboard.agents.selection"
}
