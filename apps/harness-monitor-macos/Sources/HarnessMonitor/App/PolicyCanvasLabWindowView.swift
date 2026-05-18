import HarnessMonitorKit
import HarnessMonitorUIPreviewable
import SwiftUI

struct PolicyCanvasLabSeed {
  let document: TaskBoardPolicyPipelineDocument
  let simulation: TaskBoardPolicyPipelineSimulationResult?
  let audit: TaskBoardPolicyPipelineAuditSummary?
  let allowsEmptyLiveSnapshot: Bool
}

enum PolicyCanvasLabSnapshotSupport {
  static func initialSeed(
    document: TaskBoardPolicyPipelineDocument?,
    simulation: TaskBoardPolicyPipelineSimulationResult?,
    audit: TaskBoardPolicyPipelineAuditSummary?
  ) -> PolicyCanvasLabSeed {
    if let document, hasVisibleGraph(document) {
      return PolicyCanvasLabSeed(
        document: document,
        simulation: simulation,
        audit: audit,
        allowsEmptyLiveSnapshot: true
      )
    }

    let previewDocument = PreviewFixtures.policyCanvasPipelineDocument()
    return PolicyCanvasLabSeed(
      document: previewDocument,
      simulation: nil,
      audit: PreviewFixtures.policyCanvasAudit(for: previewDocument),
      allowsEmptyLiveSnapshot: false
    )
  }

  static func shouldAdoptLiveSnapshot(
    document: TaskBoardPolicyPipelineDocument?,
    allowsEmptyLiveSnapshot: Bool
  ) -> Bool {
    guard let document else {
      return false
    }
    return allowsEmptyLiveSnapshot || hasVisibleGraph(document)
  }

  static func hasVisibleGraph(_ document: TaskBoardPolicyPipelineDocument) -> Bool {
    !document.nodes.isEmpty
  }
}

private struct PolicyCanvasLabLiveSnapshot: Equatable {
  let document: TaskBoardPolicyPipelineDocument?
  let simulation: TaskBoardPolicyPipelineSimulationResult?
  let audit: TaskBoardPolicyPipelineAuditSummary?
}

struct PolicyCanvasLabWindowView: View {
  private static let minimumSize = CGSize(width: 980, height: 620)

  let store: HarnessMonitorStore
  let keyWindowObserver: KeyWindowObserver
  let windowCommandRouting: WindowCommandRoutingState
  let mcpWindowCommandRegistrar: HarnessMonitorMCPWindowCommandRegistrar
  @Binding var themeMode: HarnessMonitorThemeMode
  @State private var dashboardUI: HarnessMonitorStore.ContentDashboardSlice
  @State private var allowsEmptyLiveSnapshot: Bool

  @MainActor
  init(
    store: HarnessMonitorStore,
    keyWindowObserver: KeyWindowObserver,
    windowCommandRouting: WindowCommandRoutingState,
    mcpWindowCommandRegistrar: HarnessMonitorMCPWindowCommandRegistrar,
    themeMode: Binding<HarnessMonitorThemeMode>
  ) {
    self.store = store
    self.keyWindowObserver = keyWindowObserver
    self.windowCommandRouting = windowCommandRouting
    self.mcpWindowCommandRegistrar = mcpWindowCommandRegistrar
    _themeMode = themeMode

    let seed = PolicyCanvasLabSnapshotSupport.initialSeed(
      document: store.contentUI.dashboard.taskBoardPolicyPipeline,
      simulation: store.contentUI.dashboard.taskBoardPolicySimulation,
      audit: store.contentUI.dashboard.taskBoardPolicyAudit
    )
    let dashboardUI = HarnessMonitorStore.ContentDashboardSlice()
    dashboardUI.taskBoardPolicyPipeline = seed.document
    dashboardUI.taskBoardPolicySimulation = seed.simulation
    dashboardUI.taskBoardPolicyAudit = seed.audit
    _dashboardUI = State(initialValue: dashboardUI)
    _allowsEmptyLiveSnapshot = State(initialValue: seed.allowsEmptyLiveSnapshot)
  }

  private var liveSnapshot: PolicyCanvasLabLiveSnapshot {
    PolicyCanvasLabLiveSnapshot(
      document: store.contentUI.dashboard.taskBoardPolicyPipeline,
      simulation: store.contentUI.dashboard.taskBoardPolicySimulation,
      audit: store.contentUI.dashboard.taskBoardPolicyAudit
    )
  }

  var body: some View {
    HarnessMonitorWindowShell(
      windowID: HarnessMonitorWindowID.policyCanvasLab,
      windowTitle: "Policy Canvas Lab",
      scope: .main,
      minimumSize: Self.minimumSize,
      keyWindowObserver: keyWindowObserver,
      windowCommandRouting: windowCommandRouting,
      mcpWindowCommandRegistrar: mcpWindowCommandRegistrar,
      themeMode: $themeMode,
      appliesPreferredColorScheme: true,
      windowToolbarBackgroundVisibility: .automatic,
      toast: store.toast
    ) {
      PolicyCanvasViewportSurface(
        document: dashboardUI.taskBoardPolicyPipeline,
        simulation: dashboardUI.taskBoardPolicySimulation,
        audit: dashboardUI.taskBoardPolicyAudit
      )
      .toolbar {}
    }
    .task {
      await bootstrapLivePolicy()
    }
    .onChange(of: liveSnapshot) { _, newSnapshot in
      adoptLiveSnapshotIfNeeded(newSnapshot)
    }
  }

  @MainActor
  private func bootstrapLivePolicy() async {
    await store.bootstrapIfNeeded()
    await store.refreshTaskBoardPolicyPipeline()
    adoptLiveSnapshotIfNeeded(liveSnapshot)
  }

  @MainActor
  private func adoptLiveSnapshotIfNeeded(_ snapshot: PolicyCanvasLabLiveSnapshot) {
    guard
      PolicyCanvasLabSnapshotSupport.shouldAdoptLiveSnapshot(
        document: snapshot.document,
        allowsEmptyLiveSnapshot: allowsEmptyLiveSnapshot
      )
    else {
      return
    }

    dashboardUI.taskBoardPolicyPipeline = snapshot.document
    dashboardUI.taskBoardPolicySimulation = snapshot.simulation
    dashboardUI.taskBoardPolicyAudit = snapshot.audit
    if let document = snapshot.document,
      PolicyCanvasLabSnapshotSupport.hasVisibleGraph(document)
    {
      allowsEmptyLiveSnapshot = true
    }
  }
}
