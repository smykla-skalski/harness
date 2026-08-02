import AppKit
import HarnessMonitorKit
import SwiftUI

#Preview("Dashboard Agents — live") {
  DashboardAgentsPreviewSurface(state: DashboardAgentsPreviewFixtures.liveState)
    .frame(width: 1040, height: 700)
}

public enum DashboardAgentsPreviewRenderer {
  @MainActor
  public static func dump(toDirectory directory: String) -> Bool {
    do {
      try FileManager.default.createDirectory(
        atPath: directory,
        withIntermediateDirectories: true
      )
    } catch {
      return false
    }

    let defaultIndex = HarnessMonitorTextSize.defaultIndex
    let largestIndex = HarnessMonitorTextSize.scales.count - 1
    return render(
      name: "agents-live",
      state: DashboardAgentsPreviewFixtures.liveState,
      textSizeIndex: defaultIndex,
      directory: directory
    )
      && render(
        name: "agents-first-run",
        state: DashboardAgentsPreviewFixtures.firstRunState,
        textSizeIndex: defaultIndex,
        directory: directory
      )
      && render(
        name: "agents-live-largest-text",
        state: DashboardAgentsPreviewFixtures.liveState,
        textSizeIndex: largestIndex,
        directory: directory
      )
      && render(
        name: "agents-loading",
        state: DashboardAgentsPreviewFixtures.loadingState,
        textSizeIndex: defaultIndex,
        directory: directory
      )
      && render(
        name: "agents-empty",
        state: DashboardAgentsPreviewFixtures.emptyState,
        textSizeIndex: defaultIndex,
        directory: directory
      )
      && render(
        name: "agents-stale-cache",
        state: DashboardAgentsPreviewFixtures.cachedState,
        textSizeIndex: defaultIndex,
        directory: directory
      )
      && render(
        name: "agents-offline",
        state: DashboardAgentsPreviewFixtures.offlineState,
        textSizeIndex: defaultIndex,
        directory: directory
      )
      && render(
        name: "agents-request-failure",
        state: DashboardAgentsPreviewFixtures.failureState,
        textSizeIndex: defaultIndex,
        directory: directory
      )
  }

  @MainActor
  private static func render(
    name: String,
    state: DashboardAgentBrowserViewState,
    textSizeIndex: Int,
    directory: String
  ) -> Bool {
    let size = NSSize(width: 1040, height: 700)
    let hosted = DashboardAgentsPreviewSurface(state: state)
      .frame(width: size.width, height: size.height)
      .background(Color(nsColor: .windowBackgroundColor))
      .harnessPreviewSceneAppearance(textSizeIndex: textSizeIndex)
    let view = NSHostingView(rootView: hosted)
    view.appearance = NSAppearance(named: .darkAqua)
    view.setFrameSize(size)
    let window = NSWindow(
      contentRect: view.bounds,
      styleMask: .borderless,
      backing: .buffered,
      defer: false,
      screen: NSScreen.main
    )
    window.contentView = view
    view.layoutSubtreeIfNeeded()
    RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.05))
    view.layoutSubtreeIfNeeded()

    guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
      return false
    }
    view.cacheDisplay(in: view.bounds, to: bitmap)
    guard let data = bitmap.representation(using: .png, properties: [:]), !data.isEmpty else {
      return false
    }
    do {
      try data.write(
        to: URL(fileURLWithPath: directory)
          .appendingPathComponent(name)
          .appendingPathExtension("png"),
        options: .atomic
      )
      return true
    } catch {
      return false
    }
  }
}

private struct DashboardAgentsPreviewSurface: View {
  let state: DashboardAgentBrowserViewState
  private let store: HarnessMonitorStore
  private let history: GlobalWindowNavigationHistory
  private let selectionDefaults: UserDefaults

  @MainActor
  init(state: DashboardAgentBrowserViewState) {
    self.state = state
    let store = HarnessMonitorPreviewStoreFactory.makeStore(for: .dashboardLoaded)
    self.store = store
    history = GlobalWindowNavigationHistory(store: store, initialDashboardRoute: .agents)
    let suiteName = "HarnessMonitorPreview.DashboardAgents.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName) ?? .standard
    defaults.set(
      state.agents.first?.identity.selectionRawValue ?? "",
      forKey: DashboardAgentSelectionDefaults.storageKey
    )
    selectionDefaults = defaults
  }

  var body: some View {
    DashboardAgentsRouteView(
      store: store,
      sessions: [],
      history: history,
      isRouteVisible: true,
      refreshesAutomatically: false,
      initialState: state,
      selectionDefaults: selectionDefaults
    )
  }
}

private enum DashboardAgentsPreviewFixtures {
  static let liveAgents = [
    agent(
      .init(
        projectID: "harness-project",
        projectName: "harness",
        checkoutID: "main",
        checkoutName: "main",
        runtime: .terminal,
        managedID: "terminal-01",
        name: "Release checks",
        lifecycle: .active,
        summary: "Running the focused Monitor tests before delivery"
      )
    ),
    agent(
      .init(
        projectID: "harness-project",
        projectName: "harness",
        checkoutID: "main",
        checkoutName: "main",
        runtime: .codex,
        managedID: "codex-01",
        name: "Dashboard agent browser",
        lifecycle: .waiting,
        summary: "Waiting for preview approval before creating the signed replay commit"
      )
    ),
    agent(
      .init(
        projectID: "mesh-project",
        projectName: "kong-mesh",
        checkoutID: "jwt-review",
        checkoutName: "jwt-review",
        runtime: .acp,
        managedID: "agent-01",
        name: "JWT review",
        lifecycle: .idle,
        summary: "Review complete; no unresolved findings remain"
      )
    ),
  ]

  static let liveState = DashboardAgentBrowserViewState(
    agents: liveAgents,
    hasAttemptedLoad: true,
    source: .live,
    refreshedAt: Date(timeIntervalSince1970: 1_785_667_200)
  )
  static let firstRunState = DashboardAgentBrowserViewState()
  static let loadingState = DashboardAgentBrowserViewState(
    isLoading: true,
    hasAttemptedLoad: true
  )
  static let emptyState = DashboardAgentBrowserViewState(
    hasAttemptedLoad: true,
    source: .live,
    refreshedAt: Date(timeIntervalSince1970: 1_785_667_200)
  )
  static let cachedState = DashboardAgentBrowserViewState(
    agents: liveAgents.map { $0.cachedCopy },
    hasAttemptedLoad: true,
    source: .cache,
    cachedAt: Date(timeIntervalSince1970: 1_785_663_600)
  )
  static let offlineState = DashboardAgentBrowserViewState(
    agents: liveAgents.map { $0.cachedCopy },
    hasAttemptedLoad: true,
    source: .cache,
    issue: .offline("Daemon is offline"),
    cachedAt: Date(timeIntervalSince1970: 1_785_663_600)
  )
  static let failureState = DashboardAgentBrowserViewState(
    hasAttemptedLoad: true,
    source: .live,
    issue: .requestFailure("The daemon returned an unexpected response")
  )

  private static func agent(_ spec: DashboardAgentPreviewSpec) -> DashboardAgentSummary {
    let workspaceIdentity = DashboardAgentWorkspaceIdentity(
      projectID: spec.projectID,
      checkoutID: spec.checkoutID
    )
    let path = "/Users/example/Projects/\(spec.projectName)/\(spec.checkoutName)"
    return DashboardAgentSummary(
      identity: DashboardAgentIdentity(
        workspace: workspaceIdentity,
        runtimeKind: spec.runtime,
        managedAgentID: spec.managedID
      ),
      workspace: DashboardAgentWorkspace(
        identity: workspaceIdentity,
        projectName: spec.projectName,
        checkoutName: spec.checkoutName,
        checkoutRoot: path
      ),
      sessionID: "opaque-preview-correlation",
      sessionAgentID: nil,
      displayName: spec.name,
      lifecycle: spec.lifecycle,
      summary: spec.summary,
      projectDirectory: path,
      createdAt: "2026-08-02T10:00:00Z",
      updatedAt: "2026-08-02T11:30:00Z",
      source: .live
    )
  }
}

private struct DashboardAgentPreviewSpec {
  let projectID: String
  let projectName: String
  let checkoutID: String
  let checkoutName: String
  let runtime: DashboardAgentRuntimeKind
  let managedID: String
  let name: String
  let lifecycle: DashboardAgentLifecycle
  let summary: String
}

extension DashboardAgentSummary {
  fileprivate var cachedCopy: DashboardAgentSummary {
    DashboardAgentSummary(
      identity: identity,
      workspace: workspace,
      sessionID: sessionID,
      sessionAgentID: sessionAgentID,
      displayName: displayName,
      lifecycle: lifecycle,
      summary: summary,
      projectDirectory: projectDirectory,
      createdAt: createdAt,
      updatedAt: updatedAt,
      source: .cache
    )
  }
}
