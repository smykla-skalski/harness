import Foundation
import Testing

@testable import HarnessMonitorKit
@testable import HarnessMonitorUIPreviewable

@MainActor
@Suite("Dashboard Agents route state")
struct DashboardAgentsRouteStateTests {
  @Test("First run, loading, cached content, and live empty remain distinct")
  func contentStatesRemainDistinct() throws {
    let state = DashboardAgentsRouteState()
    #expect(state.viewState.contentState == .firstRun)
    #expect(state.viewState.presentsAsFullWidthState)

    let generation = try #require(state.beginLoad(force: false))
    #expect(state.viewState.contentState == .loading)
    #expect(!state.viewState.presentsAsFullWidthState)

    state.adoptCache(
      DashboardAgentCacheSnapshot(agents: [fixtureAgent(source: .cache)], cachedAt: .now),
      generation: generation
    )
    #expect(state.viewState.contentState == .content)
    #expect(state.viewState.source == .cache)
    #expect(state.viewState.isLoading)
    #expect(!state.viewState.presentsAsFullWidthState)

    state.finishLoad(
      DashboardAgentRefreshResult(
        agents: [],
        source: .live,
        issue: nil,
        refreshedAt: .now
      ),
      generation: generation
    )
    #expect(state.viewState.contentState == .empty)
    #expect(state.viewState.source == .live)
    #expect(!state.viewState.isLoading)
    #expect(state.viewState.presentsAsFullWidthState)
  }

  @Test("Decision destinations remain content when no agents are loaded")
  func decisionOnlyContent() {
    let state = DashboardAgentBrowserViewState(hasAttemptedLoad: true)

    #expect(state.contentState(hasDecisionDestinations: true) == .content)
    #expect(!state.presentsAsFullWidthState(hasDecisionDestinations: true))
  }

  @Test("Offline and request failure remain different issues")
  func offlineAndRequestFailureRemainDifferent() throws {
    let state = DashboardAgentsRouteState()
    let offlineGeneration = try #require(state.beginLoad(force: false))
    state.finishLoad(
      DashboardAgentRefreshResult(
        agents: [],
        source: .cache,
        issue: .offline("No connection"),
        refreshedAt: .now
      ),
      generation: offlineGeneration
    )
    #expect(state.viewState.issue == .offline("No connection"))
    #expect(state.viewState.presentsAsFullWidthState)

    let failureGeneration = try #require(state.beginLoad(force: true))
    state.finishLoad(
      DashboardAgentRefreshResult(
        agents: [],
        source: .cache,
        issue: .requestFailure("Timed out"),
        refreshedAt: .now
      ),
      generation: failureGeneration
    )
    #expect(state.viewState.issue == .requestFailure("Timed out"))
    #expect(state.viewState.presentsAsFullWidthState)

    let cachedState = DashboardAgentsRouteState(
      viewState: DashboardAgentBrowserViewState(
        agents: [fixtureAgent(source: .cache)],
        hasAttemptedLoad: true,
        source: .cache,
        issue: .offline("No connection")
      )
    )
    #expect(!cachedState.viewState.presentsAsFullWidthState)
  }

  @Test("Late refresh cannot replace a newer workspace snapshot")
  func lateRefreshCannotReplaceNewerSnapshot() throws {
    let state = DashboardAgentsRouteState()
    let oldGeneration = try #require(state.beginLoad(force: false))
    let newGeneration = try #require(state.beginLoad(force: true))
    let newest = fixtureAgent(source: .live, name: "Newest")
    state.finishLoad(
      DashboardAgentRefreshResult(
        agents: [newest],
        source: .live,
        issue: nil,
        refreshedAt: .now
      ),
      generation: newGeneration
    )
    state.finishLoad(
      DashboardAgentRefreshResult(
        agents: [fixtureAgent(source: .cache, name: "Old")],
        source: .cache,
        issue: nil,
        refreshedAt: .now
      ),
      generation: oldGeneration
    )

    #expect(state.viewState.agents.map(\.displayName) == ["Newest"])
    #expect(state.viewState.source == .live)
  }
}

private func fixtureAgent(
  source: DashboardAgentDataSource,
  name: String = "Worker"
) -> DashboardAgentSummary {
  let workspace = DashboardAgentWorkspace(
    identity: DashboardAgentWorkspaceIdentity(projectID: "harness", checkoutID: "main"),
    projectName: "Harness",
    checkoutName: "main",
    checkoutRoot: "/tmp/harness"
  )
  return DashboardAgentSummary(
    identity: DashboardAgentIdentity(
      workspace: workspace.identity,
      runtimeKind: .terminal,
      managedAgentID: "terminal-1"
    ),
    workspace: workspace,
    sessionID: "session-1",
    sessionAgentID: "worker-1",
    displayName: name,
    lifecycle: .active,
    summary: "Working",
    projectDirectory: workspace.checkoutRoot,
    createdAt: "2026-08-02T08:00:00Z",
    updatedAt: "2026-08-02T09:00:00Z",
    source: source
  )
}
