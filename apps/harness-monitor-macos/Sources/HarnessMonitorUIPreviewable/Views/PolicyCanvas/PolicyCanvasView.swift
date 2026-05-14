import HarnessMonitorKit
import SwiftUI

public struct PolicyCanvasView: View {
  @State private var viewModel: PolicyCanvasViewModel
  @State private var isShowingPromoteConfirmation = false
  private let store: HarnessMonitorStore?
  private let dashboardUI: HarnessMonitorStore.ContentDashboardSlice?

  public init() {
    _viewModel = State(initialValue: .sample())
    self.store = nil
    self.dashboardUI = nil
  }

  public init(
    store: HarnessMonitorStore,
    dashboardUI: HarnessMonitorStore.ContentDashboardSlice
  ) {
    _viewModel = State(initialValue: .sample())
    self.store = store
    self.dashboardUI = dashboardUI
  }

  init(viewModel: PolicyCanvasViewModel) {
    _viewModel = State(initialValue: viewModel)
    self.store = nil
    self.dashboardUI = nil
  }

  init(
    viewModel: PolicyCanvasViewModel,
    store: HarnessMonitorStore,
    dashboardUI: HarnessMonitorStore.ContentDashboardSlice
  ) {
    _viewModel = State(initialValue: viewModel)
    self.store = store
    self.dashboardUI = dashboardUI
  }

  public var body: some View {
    VStack(spacing: 0) {
      PolicyCanvasTopBar(
        viewModel: viewModel,
        canPromote: viewModel.canPromote,
        save: saveDraft,
        simulate: simulate,
        promote: requestPromote
      )

      HStack(spacing: 0) {
        PolicyCanvasToolRail(viewModel: viewModel)

        PolicyCanvasViewport(viewModel: viewModel)
          .frame(maxWidth: .infinity, maxHeight: .infinity)

        PolicyCanvasInspector(viewModel: viewModel)
          .frame(width: 280)
      }
    }
    .frame(minWidth: 980, minHeight: 620)
    .background(Color(red: 0.05, green: 0.06, blue: 0.08))
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier(HarnessMonitorAccessibility.policyCanvasRoot)
    .task {
      await loadPolicyPipeline()
    }
    .onChange(of: dashboardUI?.taskBoardPolicyPipeline) { _, newValue in
      viewModel.loadIfChanged(
        document: newValue,
        simulation: dashboardUI?.taskBoardPolicySimulation,
        audit: dashboardUI?.taskBoardPolicyAudit
      )
    }
    .onChange(of: dashboardUI?.taskBoardPolicySimulation) { _, newValue in
      viewModel.loadIfChanged(
        document: dashboardUI?.taskBoardPolicyPipeline,
        simulation: newValue,
        audit: dashboardUI?.taskBoardPolicyAudit
      )
    }
    .confirmationDialog(
      "Promote policy pipeline?",
      isPresented: $isShowingPromoteConfirmation,
      titleVisibility: .visible
    ) {
      Button("Promote", role: .destructive) {
        confirmPromote()
      }
      Button("Cancel", role: .cancel) {}
    } message: {
      Text("The saved revision will become the enforced automation policy.")
    }
  }

  private func loadPolicyPipeline() async {
    guard let store else {
      return
    }
    if let cachedDocument = dashboardUI?.taskBoardPolicyPipeline {
      viewModel.loadIfChanged(
        document: cachedDocument,
        simulation: dashboardUI?.taskBoardPolicySimulation,
        audit: dashboardUI?.taskBoardPolicyAudit
      )
      return
    }
    guard viewModel.markInitialRemoteLoadRequested() else {
      return
    }
    await store.refreshTaskBoardPolicyPipeline()
    viewModel.loadIfChanged(
      document: dashboardUI?.taskBoardPolicyPipeline,
      simulation: dashboardUI?.taskBoardPolicySimulation,
      audit: dashboardUI?.taskBoardPolicyAudit,
      force: true
    )
  }

  private func saveDraft() {
    let document = viewModel.exportDocument()
    Task { @MainActor in
      let saved = await store?.saveTaskBoardPolicyPipelineDraft(document: document) ?? false
      if saved {
        await forceReloadPolicyPipeline()
      } else {
        viewModel.lastActionSummary = "Save blocked by validation"
      }
    }
  }

  private func simulate() {
    let document = viewModel.exportDocument()
    Task { @MainActor in
      let simulated = await store?.simulateTaskBoardPolicyPipeline(document: document) ?? false
      if simulated {
        await forceReloadPolicyPipeline()
      } else {
        viewModel.lastActionSummary = "Simulation failed"
      }
    }
  }

  private func requestPromote() {
    guard viewModel.canPromote, let revision = viewModel.backingDocument?.revision else {
      viewModel.lastActionSummary = "Promote requires a saved matching simulation"
      return
    }
    viewModel.lastActionSummary = "Confirm promotion for revision \(revision)"
    isShowingPromoteConfirmation = true
  }

  private func confirmPromote() {
    guard viewModel.canPromote, let revision = viewModel.backingDocument?.revision else {
      viewModel.lastActionSummary = "Promote requires a saved matching simulation"
      return
    }
    Task { @MainActor in
      let promoted = await store?.promoteTaskBoardPolicyPipeline(revision: revision) ?? false
      if promoted {
        await forceReloadPolicyPipeline()
      } else {
        viewModel.lastActionSummary = "Promotion blocked"
      }
    }
  }

  private func forceReloadPolicyPipeline() async {
    guard let store else {
      return
    }
    await store.refreshTaskBoardPolicyPipeline()
    viewModel.loadIfChanged(
      document: dashboardUI?.taskBoardPolicyPipeline,
      simulation: dashboardUI?.taskBoardPolicySimulation,
      audit: dashboardUI?.taskBoardPolicyAudit,
      force: true
    )
  }
}
