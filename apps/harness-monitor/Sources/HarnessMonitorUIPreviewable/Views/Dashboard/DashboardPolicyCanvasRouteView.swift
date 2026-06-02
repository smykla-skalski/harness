import Foundation
import HarnessMonitorKit
import SwiftUI

private struct DashboardPolicyCanvasRefreshTaskID: Equatable {
  let isRouteVisible: Bool
  let connectionState: HarnessMonitorStore.ConnectionState
  let needsInitialRefresh: Bool
}

struct DashboardPolicyCanvasRouteView: View {
  let store: HarnessMonitorStore
  let dashboardUI: HarnessMonitorStore.ContentDashboardSlice
  let isRouteVisible: Bool

  @State var policyCanvasViewModel: PolicyCanvasViewModel
  @State private var selectedCanvasId: String?
  @State private var editingCanvasId: String?
  @State private var pendingNameRequest: DashboardPolicyCanvasNameRequest?
  @State private var pendingSwitchMutation: DashboardPolicyCanvasSwitchMutation?
  @State private var pendingDeleteRequest: DashboardPolicyCanvasDeleteRequest?
  @State private var suppressCanvasSelectionHandling = false
  @State private var isAutomationPolicySheetPresented = false
  @State var selectedCanvasPreview: DashboardPolicyCanvasSelectionPreview?

  @MainActor
  init(
    store: HarnessMonitorStore,
    dashboardUI: HarnessMonitorStore.ContentDashboardSlice,
    isRouteVisible: Bool
  ) {
    self.store = store
    self.dashboardUI = dashboardUI
    self.isRouteVisible = isRouteVisible
    _policyCanvasViewModel = State(
      initialValue: PolicyCanvasViewModel.liveStartupState(
        document: dashboardUI.taskBoardPolicyPipeline,
        simulation: dashboardUI.taskBoardPolicySimulation,
        audit: dashboardUI.taskBoardPolicyAudit,
        activeCanvasId: dashboardUI.taskBoardPolicyCanvasWorkspace?.activeCanvasId
      )
    )
    _selectedCanvasId = State(
      initialValue: dashboardUI.taskBoardPolicyCanvasWorkspace?.activeCanvasId)
  }

  var workspace: TaskBoardPolicyCanvasWorkspace? {
    dashboardUI.taskBoardPolicyCanvasWorkspace
  }

  private var detailUsesLiveCanvas: Bool {
    if selectedCanvasPreview?.showsLoadingPlaceholder == true {
      return false
    }
    return dashboardUI.taskBoardPolicyPipeline != nil
      || selectedCanvasPreview?.snapshot.document != nil
      || dashboardUI.taskBoardPolicyCanvasWorkspace != nil
  }

  private var isCanvasMutationDisabled: Bool {
    dashboardUI.isBusy || store.isDaemonActionInFlight
  }

  private var refreshTaskID: DashboardPolicyCanvasRefreshTaskID {
    DashboardPolicyCanvasRefreshTaskID(
      isRouteVisible: isRouteVisible,
      connectionState: dashboardUI.connectionState,
      needsInitialRefresh: workspace == nil
    )
  }

  private var canvasIDs: [String] {
    workspace?.canvases.map(\.canvasId) ?? []
  }

  private var switchConfirmationPresented: Binding<Bool> {
    Binding(
      get: { pendingSwitchMutation != nil },
      set: { isPresented in
        if !isPresented {
          pendingSwitchMutation = nil
          syncCanvasSelectionToActiveCanvas()
        }
      }
    )
  }

  private var deleteConfirmationPresented: Binding<Bool> {
    Binding(
      get: { pendingDeleteRequest != nil },
      set: { isPresented in
        if !isPresented {
          pendingDeleteRequest = nil
        }
      }
    )
  }

  var body: some View {
    let routeContent = SessionContentDetailSplitView(
      detail: { detailPane },
      footer: {
        DashboardPolicyCanvasFooterBar(
          workspace: workspace,
          fallbackDocument: dashboardUI.taskBoardPolicyPipeline,
          selectedCanvasId: selectedCanvasId,
          policyCanvasViewModel: policyCanvasViewModel,
          automationPolicyCenter: AutomationPolicyCenter.shared,
          isCanvasMutationDisabled: isCanvasMutationDisabled,
          editingCanvasId: editingCanvasId,
          isAutomationPolicySheetPresented: $isAutomationPolicySheetPresented,
          createCanvas: requestCreateCanvas,
          selectCanvas: { selectedCanvasId = $0.canvasId },
          duplicateCanvasFromTab: requestDuplicateCanvas,
          renameCanvasFromTab: requestRenameCanvas,
          submitRenameCanvasFromTab: submitRenameCanvasFromTab,
          cancelRenameCanvasFromTab: cancelRenameCanvasFromTab,
          deleteCanvasFromTab: requestDeleteCanvas,
          onExport: requestExportCanvas,
          onImport: requestImportCanvas
        )
      }
    )
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .task(id: refreshTaskID) {
      guard isRouteVisible else {
        return
      }
      if workspace == nil {
        await refreshWorkspaceIfNeeded()
      }
      syncCanvasSelectionToActiveCanvas()
    }
    .onChange(of: dashboardUI.taskBoardPolicyCanvasWorkspace?.activeCanvasId) { _, _ in
      clearCanvasSelectionPreview()
      syncCanvasSelectionToActiveCanvas()
    }
    .onChange(of: selectedCanvasId) { _, newValue in
      handleCanvasSelectionChange(newValue)
    }
    .onChange(of: canvasIDs) { _, ids in
      if let editingCanvasId, !ids.contains(editingCanvasId) {
        self.editingCanvasId = nil
      }
    }
    .sheet(item: $pendingNameRequest) { request in
      DashboardPolicyCanvasNameSheet(request: request) { title in
        submitNameRequest(request, title: title)
      }
    }
    .sheet(isPresented: $isAutomationPolicySheetPresented) {
      PolicyCanvasAutomationPolicySheet(viewModel: policyCanvasViewModel)
    }
    .confirmationDialog(
      "Unsaved Changes",
      isPresented: switchConfirmationPresented,
      titleVisibility: .visible,
      presenting: pendingSwitchMutation
    ) { mutation in
      Button("Save and Continue") {
        Task { await saveThenPerformSwitchMutation(mutation) }
      }
      Button("Discard Changes and Continue", role: .destructive) {
        Task { await discardThenPerformSwitchMutation(mutation) }
      }
      Button("Cancel", role: .cancel) {
        syncCanvasSelectionToActiveCanvas()
      }
    } message: { mutation in
      Text(mutation.confirmationMessage)
    }
    .confirmationDialog(
      "Delete Policy Canvas?",
      isPresented: deleteConfirmationPresented,
      titleVisibility: .visible,
      presenting: pendingDeleteRequest
    ) { request in
      if request.requiresDirtyResolution {
        Button("Save and Delete", role: .destructive) {
          Task { await saveThenDeleteCanvas(request.canvas) }
        }
        Button("Delete Without Saving", role: .destructive) {
          Task { await discardThenDeleteCanvas(request.canvas) }
        }
      } else {
        Button("Delete Canvas", role: .destructive) {
          Task { await deleteCanvas(request.canvas) }
        }
      }
      Button("Cancel", role: .cancel) {}
    } message: { request in
      Text(request.message)
    }

    routeContent
  }

  @ViewBuilder private var detailPane: some View {
    if detailUsesLiveCanvas {
      PolicyCanvasView(
        viewModel: policyCanvasViewModel,
        store: store,
        dashboardUI: dashboardUI,
        dashboardSnapshotOverride: selectedCanvasPreview?.snapshot,
        sceneFocusEnabled: isRouteVisible
      )
      .frame(maxWidth: .infinity, maxHeight: .infinity)
    } else {
      ContentUnavailableView(
        "Loading Policies",
        systemImage: "rectangle.on.rectangle",
        description: Text(
          "Policies will appear here once the workspace finishes loading."
        )
      )
      .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
  }

  @MainActor
  private func refreshWorkspaceIfNeeded() async {
    guard workspace == nil else {
      return
    }
    await store.bootstrapIfNeeded()
    await store.refreshTaskBoardPolicyPipeline()
  }

  private func requestCreateCanvas() {
    pendingNameRequest = DashboardPolicyCanvasNameRequest.create(
      initialTitle: nextCanvasTitle
    )
  }

  private func requestDuplicateCanvas(_ canvas: TaskBoardPolicyCanvasSummary) {
    pendingNameRequest = DashboardPolicyCanvasNameRequest.duplicate(
      source: canvas,
      initialTitle: "\(canvas.title) Copy"
    )
  }

  private func requestRenameCanvas(_ canvas: TaskBoardPolicyCanvasSummary) {
    editingCanvasId = canvas.canvasId
  }

  private func syncCanvasSelectionToActiveCanvas() {
    guard !suppressCanvasSelectionHandling else {
      return
    }
    suppressCanvasSelectionHandling = true
    selectedCanvasId = workspace?.activeCanvasId
    suppressCanvasSelectionHandling = false
  }

  private func handleCanvasSelectionChange(_ newValue: String?) {
    guard !suppressCanvasSelectionHandling,
      let workspace,
      let newValue,
      newValue != workspace.activeCanvasId,
      let canvas = workspace.canvases.first(where: { $0.canvasId == newValue })
    else {
      return
    }
    requestSwitchMutation(.activate(canvas))
  }

  private func submitNameRequest(
    _ request: DashboardPolicyCanvasNameRequest,
    title: String
  ) {
    let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmedTitle.isEmpty else {
      return
    }
    switch request.mode {
    case .create:
      requestSwitchMutation(.create(title: trimmedTitle))
    case .duplicate(let source):
      requestSwitchMutation(.duplicate(source: source, title: trimmedTitle))
    }
  }

  private func submitRenameCanvasFromTab(
    _ canvas: TaskBoardPolicyCanvasSummary,
    title: String
  ) {
    let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmedTitle.isEmpty else {
      return
    }
    editingCanvasId = nil
    guard trimmedTitle != canvas.title else {
      return
    }
    Task {
      _ = await store.renameTaskBoardPolicyCanvas(
        canvasId: canvas.canvasId,
        title: trimmedTitle
      )
    }
  }

  private func cancelRenameCanvasFromTab() {
    editingCanvasId = nil
  }

  private func requestSwitchMutation(_ mutation: DashboardPolicyCanvasSwitchMutation) {
    if policyCanvasViewModel.documentDirty {
      pendingSwitchMutation = mutation
      return
    }
    Task { await performSwitchMutation(mutation) }
  }

  @MainActor
  private func saveThenPerformSwitchMutation(_ mutation: DashboardPolicyCanvasSwitchMutation) async
  {
    guard await saveCurrentCanvasEdits() else {
      return
    }
    pendingSwitchMutation = nil
    await performSwitchMutation(mutation)
  }

  @MainActor
  private func discardThenPerformSwitchMutation(_ mutation: DashboardPolicyCanvasSwitchMutation)
    async
  {
    discardCurrentCanvasEdits()
    pendingSwitchMutation = nil
    await performSwitchMutation(mutation)
  }

  @MainActor
  private func performSwitchMutation(_ mutation: DashboardPolicyCanvasSwitchMutation) async {
    policyCanvasViewModel.cancelAutosave()
    switch mutation {
    case .activate(let canvas):
      applyCanvasSelectionPreview(for: canvas)
      _ = await store.activateTaskBoardPolicyCanvas(canvasId: canvas.canvasId)
      clearCanvasSelectionPreview()
    case .create(let title):
      clearCanvasSelectionPreview()
      _ = await store.createTaskBoardPolicyCanvas(title: title)
    case .duplicate(let source, let title):
      clearCanvasSelectionPreview()
      _ = await store.duplicateTaskBoardPolicyCanvas(
        canvasId: source.canvasId,
        title: title
      )
    }
    syncCanvasSelectionToActiveCanvas()
  }

  private func requestDeleteCanvas(_ canvas: TaskBoardPolicyCanvasSummary) {
    pendingDeleteRequest = DashboardPolicyCanvasDeleteRequest(
      canvas: canvas,
      requiresDirtyResolution: canvas.canvasId == workspace?.activeCanvasId
        && policyCanvasViewModel.documentDirty
    )
  }

  @MainActor
  private func saveThenDeleteCanvas(_ canvas: TaskBoardPolicyCanvasSummary) async {
    guard await saveCurrentCanvasEdits() else {
      return
    }
    pendingDeleteRequest = nil
    await deleteCanvas(canvas)
  }

  @MainActor
  private func discardThenDeleteCanvas(_ canvas: TaskBoardPolicyCanvasSummary) async {
    discardCurrentCanvasEdits()
    pendingDeleteRequest = nil
    await deleteCanvas(canvas)
  }

  @MainActor
  private func deleteCanvas(_ canvas: TaskBoardPolicyCanvasSummary) async {
    policyCanvasViewModel.cancelAutosave()
    _ = await store.deleteTaskBoardPolicyCanvas(canvasId: canvas.canvasId)
    syncCanvasSelectionToActiveCanvas()
  }

  @MainActor
  private func saveCurrentCanvasEdits() async -> Bool {
    let exportedDocument = policyCanvasViewModel.exportDocument()
    // Adopt the daemon's saved document (bumped revision), not the one we sent —
    // applying the sent revision would leave the canvas one behind the daemon
    // and re-trip the remote-change banner on the next republish.
    guard
      let savedDocument = await store.saveTaskBoardPolicyPipelineDraft(document: exportedDocument)
    else {
      return false
    }
    policyCanvasViewModel.applyDocument(
      document: savedDocument,
      simulation: dashboardUI.taskBoardPolicySimulation,
      audit: dashboardUI.taskBoardPolicyAudit,
      activeCanvasId: dashboardUI.taskBoardPolicyCanvasWorkspace?.activeCanvasId,
      forceDocumentReload: true
    )
    return true
  }

  private func discardCurrentCanvasEdits() {
    policyCanvasViewModel.cancelAutosave()
    policyCanvasViewModel.applyDocument(
      document: dashboardUI.taskBoardPolicyPipeline,
      simulation: dashboardUI.taskBoardPolicySimulation,
      audit: dashboardUI.taskBoardPolicyAudit,
      activeCanvasId: dashboardUI.taskBoardPolicyCanvasWorkspace?.activeCanvasId,
      forceDocumentReload: true
    )
  }

}
