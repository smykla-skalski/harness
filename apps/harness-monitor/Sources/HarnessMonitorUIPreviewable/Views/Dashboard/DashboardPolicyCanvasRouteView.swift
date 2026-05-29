import Foundation
import HarnessMonitorKit
import SwiftUI

enum DashboardPolicyCanvasContentDetailWidthRestoration {
  static let storageKey = "dashboard.policy-canvas.content-detail-width"
  static let defaultWidth = 280.0
}

private struct DashboardPolicyCanvasRefreshTaskID: Equatable {
  let isRouteVisible: Bool
  let connectionState: HarnessMonitorStore.ConnectionState
  let needsInitialRefresh: Bool
}

struct DashboardPolicyCanvasRouteView: View {
  let store: HarnessMonitorStore
  let dashboardUI: HarnessMonitorStore.ContentDashboardSlice
  let isRouteVisible: Bool

  @AppStorage(DashboardPolicyCanvasContentDetailWidthRestoration.storageKey)
  var contentDetailWidth = DashboardPolicyCanvasContentDetailWidthRestoration.defaultWidth
  @State private var policyCanvasViewModel: PolicyCanvasViewModel
  @State private var sidebarSelection: String?
  @State private var pendingNameRequest: DashboardPolicyCanvasNameRequest?
  @State private var pendingSwitchMutation: DashboardPolicyCanvasSwitchMutation?
  @State private var pendingDeleteRequest: DashboardPolicyCanvasDeleteRequest?
  @State private var suppressSidebarSelectionHandling = false

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
    _sidebarSelection = State(initialValue: dashboardUI.taskBoardPolicyCanvasWorkspace?.activeCanvasId)
  }

  private var workspace: TaskBoardPolicyCanvasWorkspace? {
    dashboardUI.taskBoardPolicyCanvasWorkspace
  }

  private var activeCanvas: TaskBoardPolicyCanvasSummary? {
    guard let workspace else {
      return nil
    }
    return workspace.canvases.first(where: { $0.canvasId == workspace.activeCanvasId })
  }

  private var selectedCanvas: TaskBoardPolicyCanvasSummary? {
    guard let workspace else {
      return nil
    }
    let resolvedSelection = sidebarSelection ?? workspace.activeCanvasId
    return workspace.canvases.first(where: { $0.canvasId == resolvedSelection })
  }

  private var detailUsesLiveCanvas: Bool {
    dashboardUI.taskBoardPolicyPipeline != nil
      || dashboardUI.taskBoardPolicyCanvasWorkspace != nil
  }

  private var isCanvasMutationDisabled: Bool {
    dashboardUI.isBusy || store.isDaemonActionInFlight
  }

  private var refreshTaskID: DashboardPolicyCanvasRefreshTaskID {
    DashboardPolicyCanvasRefreshTaskID(
      isRouteVisible: isRouteVisible,
      connectionState: dashboardUI.connectionState,
      needsInitialRefresh: workspace == nil && dashboardUI.taskBoardPolicyPipeline == nil
    )
  }

  private var switchConfirmationPresented: Binding<Bool> {
    Binding(
      get: { pendingSwitchMutation != nil },
      set: { isPresented in
        if !isPresented {
          pendingSwitchMutation = nil
          syncSidebarSelectionToActiveCanvas()
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
    let splitView = SessionContentDetailSplitView(
      contentWidth: $contentDetailWidth,
      commitContentWidth: { contentDetailWidth = $0 },
      dividerAccessibilityIdentifier:
        HarnessMonitorAccessibility.dashboardPolicyCanvasDetailDivider,
      showsDividerLine: false,
      content: { sidebarPane },
      detail: { detailPane }
    )
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .task(id: refreshTaskID) {
      guard isRouteVisible else {
        return
      }
      if workspace == nil && dashboardUI.taskBoardPolicyPipeline == nil {
        await refreshWorkspaceIfNeeded()
      }
      syncSidebarSelectionToActiveCanvas()
    }
    .onChange(of: dashboardUI.taskBoardPolicyCanvasWorkspace?.activeCanvasId) { _, _ in
      syncSidebarSelectionToActiveCanvas()
    }
    .onChange(of: sidebarSelection) { _, newValue in
      handleSidebarSelectionChange(newValue)
    }
    .sheet(item: $pendingNameRequest) { request in
      DashboardPolicyCanvasNameSheet(request: request) { title in
        submitNameRequest(request, title: title)
      }
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
        syncSidebarSelectionToActiveCanvas()
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

    splitView
  }

  @ViewBuilder
  private var sidebarPane: some View {
    VStack(spacing: 0) {
      HStack(spacing: HarnessMonitorTheme.spacingSM) {
        Text("Canvases")
          .font(.headline)
        Spacer()
        Button {
          pendingNameRequest = DashboardPolicyCanvasNameRequest.create(
            initialTitle: nextCanvasTitle
          )
        } label: {
          Label("New Canvas", systemImage: "plus")
            .labelStyle(.iconOnly)
        }
        .disabled(isCanvasMutationDisabled)
        .help("Create a new policy canvas")
      }
      .padding(.horizontal, HarnessMonitorTheme.spacingMD)
      .padding(.vertical, HarnessMonitorTheme.spacingSM)

      Divider()

      if let workspace {
        List(selection: $sidebarSelection) {
          ForEach(workspace.canvases) { canvas in
            DashboardPolicyCanvasSidebarRow(
              canvas: canvas,
              isActive: canvas.canvasId == workspace.activeCanvasId
            )
            .tag(Optional.some(canvas.canvasId))
            .contextMenu {
              Button("Duplicate") {
                pendingNameRequest = DashboardPolicyCanvasNameRequest.duplicate(
                  source: canvas,
                  initialTitle: "\(canvas.title) Copy"
                )
              }
              Button("Rename") {
                pendingNameRequest = DashboardPolicyCanvasNameRequest.rename(
                  canvas: canvas,
                  initialTitle: canvas.title
                )
              }
              Divider()
              Button("Delete", role: .destructive) {
                requestDeleteCanvas(canvas)
              }
            }
          }
        }
        .listStyle(.sidebar)
      } else {
        ContentUnavailableView(
          "Loading Canvases",
          systemImage: "square.on.square",
          description: Text("Fetching the policy canvas workspace from the daemon.")
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
      }

      Divider()

      HStack(spacing: HarnessMonitorTheme.spacingSM) {
        Button("Duplicate") {
          guard let selectedCanvas else {
            return
          }
          pendingNameRequest = DashboardPolicyCanvasNameRequest.duplicate(
            source: selectedCanvas,
            initialTitle: "\(selectedCanvas.title) Copy"
          )
        }
        .disabled(selectedCanvas == nil || isCanvasMutationDisabled)

        Button("Rename") {
          guard let selectedCanvas else {
            return
          }
          pendingNameRequest = DashboardPolicyCanvasNameRequest.rename(
            canvas: selectedCanvas,
            initialTitle: selectedCanvas.title
          )
        }
        .disabled(selectedCanvas == nil || isCanvasMutationDisabled)

        Button("Delete", role: .destructive) {
          guard let selectedCanvas else {
            return
          }
          requestDeleteCanvas(selectedCanvas)
        }
        .disabled(selectedCanvas == nil || isCanvasMutationDisabled)
      }
      .padding(.horizontal, HarnessMonitorTheme.spacingMD)
      .padding(.vertical, HarnessMonitorTheme.spacingSM)
    }
    .background(.background)
  }

  @ViewBuilder
  private var detailPane: some View {
    if detailUsesLiveCanvas {
      PolicyCanvasView(
        viewModel: policyCanvasViewModel,
        store: store,
        dashboardUI: dashboardUI,
        sceneFocusEnabled: isRouteVisible
      )
      .frame(maxWidth: .infinity, maxHeight: .infinity)
    } else {
      ContentUnavailableView(
        "Loading Policy Canvas",
        systemImage: "rectangle.on.rectangle",
        description: Text("The active policy canvas will appear here once the workspace finishes loading.")
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

  private func syncSidebarSelectionToActiveCanvas() {
    guard !suppressSidebarSelectionHandling else {
      return
    }
    suppressSidebarSelectionHandling = true
    sidebarSelection = workspace?.activeCanvasId
    suppressSidebarSelectionHandling = false
  }

  private func handleSidebarSelectionChange(_ newValue: String?) {
    guard !suppressSidebarSelectionHandling,
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
    case .rename(let canvas):
      Task {
        _ = await store.renameTaskBoardPolicyCanvas(
          canvasId: canvas.canvasId,
          title: trimmedTitle
        )
      }
    }
  }

  private func requestSwitchMutation(_ mutation: DashboardPolicyCanvasSwitchMutation) {
    if policyCanvasViewModel.documentDirty {
      pendingSwitchMutation = mutation
      return
    }
    Task { await performSwitchMutation(mutation) }
  }

  @MainActor
  private func saveThenPerformSwitchMutation(_ mutation: DashboardPolicyCanvasSwitchMutation) async {
    guard await saveCurrentCanvasEdits() else {
      return
    }
    pendingSwitchMutation = nil
    await performSwitchMutation(mutation)
  }

  @MainActor
  private func discardThenPerformSwitchMutation(_ mutation: DashboardPolicyCanvasSwitchMutation) async {
    discardCurrentCanvasEdits()
    pendingSwitchMutation = nil
    await performSwitchMutation(mutation)
  }

  @MainActor
  private func performSwitchMutation(_ mutation: DashboardPolicyCanvasSwitchMutation) async {
    policyCanvasViewModel.cancelAutosave()
    switch mutation {
    case .activate(let canvas):
      _ = await store.activateTaskBoardPolicyCanvas(canvasId: canvas.canvasId)
    case .create(let title):
      _ = await store.createTaskBoardPolicyCanvas(title: title)
    case .duplicate(let source, let title):
      _ = await store.duplicateTaskBoardPolicyCanvas(
        canvasId: source.canvasId,
        title: title
      )
    }
    syncSidebarSelectionToActiveCanvas()
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
    syncSidebarSelectionToActiveCanvas()
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

  private var nextCanvasTitle: String {
    let nextIndex = (workspace?.canvases.count ?? 0) + 1
    return "Policy Canvas \(nextIndex)"
  }
}

private struct DashboardPolicyCanvasSidebarRow: View {
  let canvas: TaskBoardPolicyCanvasSummary
  let isActive: Bool

  var body: some View {
    VStack(alignment: .leading, spacing: HarnessMonitorTheme.spacingXS) {
      HStack(spacing: HarnessMonitorTheme.spacingXS) {
        Text(canvas.title)
          .font(.body.weight(.medium))
          .lineLimit(1)
        Spacer(minLength: 0)
        if isActive {
          Text("Active")
            .font(.caption.weight(.semibold))
            .foregroundStyle(.tint)
        }
      }

      HStack(spacing: HarnessMonitorTheme.spacingXS) {
        Text("r\(canvas.revision)")
        Text("\(canvas.nodeCount) nodes")
        Text("\(canvas.groupCount) groups")
      }
      .font(.caption)
      .foregroundStyle(.secondary)

      if let latestSimulationSucceeded = canvas.latestSimulationSucceeded {
        Label(
          latestSimulationSucceeded ? "Latest simulation passed" : "Latest simulation found issues",
          systemImage: latestSimulationSucceeded ? "checkmark.circle.fill" : "exclamationmark.triangle.fill"
        )
        .font(.caption)
        .foregroundStyle(latestSimulationSucceeded ? Color.accentColor : Color.orange)
      }
    }
    .padding(.vertical, HarnessMonitorTheme.spacingXS)
  }
}

private struct DashboardPolicyCanvasNameSheet: View {
  let request: DashboardPolicyCanvasNameRequest
  let onSubmit: @MainActor (String) -> Void

  @Environment(\.dismiss) private var dismiss
  @FocusState private var titleFieldFocused: Bool
  @State private var draftTitle: String

  init(
    request: DashboardPolicyCanvasNameRequest,
    onSubmit: @escaping @MainActor (String) -> Void
  ) {
    self.request = request
    self.onSubmit = onSubmit
    _draftTitle = State(initialValue: request.initialTitle)
  }

  private var trimmedTitle: String {
    draftTitle.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  var body: some View {
    VStack(alignment: .leading, spacing: HarnessMonitorTheme.spacingMD) {
      Text(request.title)
        .font(.title3.weight(.semibold))

      Text(request.message)
        .foregroundStyle(.secondary)

      TextField("Canvas title", text: $draftTitle)
        .textFieldStyle(.roundedBorder)
        .focused($titleFieldFocused)
        .onSubmit(submit)

      HStack {
        Spacer()
        Button("Cancel", role: .cancel) {
          dismiss()
        }
        Button(request.actionTitle, action: submit)
          .keyboardShortcut(.defaultAction)
          .disabled(trimmedTitle.isEmpty)
      }
    }
    .padding(HarnessMonitorTheme.spacingLG)
    .frame(width: 360)
    .task {
      titleFieldFocused = true
    }
  }

  @MainActor
  private func submit() {
    guard !trimmedTitle.isEmpty else {
      return
    }
    onSubmit(trimmedTitle)
    dismiss()
  }
}

private struct DashboardPolicyCanvasNameRequest: Identifiable {
  enum Mode {
    case create
    case duplicate(source: TaskBoardPolicyCanvasSummary)
    case rename(canvas: TaskBoardPolicyCanvasSummary)
  }

  let id = UUID()
  let mode: Mode
  let initialTitle: String

  static func create(initialTitle: String) -> Self {
    Self(mode: .create, initialTitle: initialTitle)
  }

  static func duplicate(
    source: TaskBoardPolicyCanvasSummary,
    initialTitle: String
  ) -> Self {
    Self(mode: .duplicate(source: source), initialTitle: initialTitle)
  }

  static func rename(
    canvas: TaskBoardPolicyCanvasSummary,
    initialTitle: String
  ) -> Self {
    Self(mode: .rename(canvas: canvas), initialTitle: initialTitle)
  }

  var title: String {
    switch mode {
    case .create:
      "Create Canvas"
    case .duplicate:
      "Duplicate Canvas"
    case .rename:
      "Rename Canvas"
    }
  }

  var message: String {
    switch mode {
    case .create:
      "Choose a name for the new policy canvas."
    case .duplicate(let source):
      "Create a copy of “\(source.title)” with a new canvas name."
    case .rename(let canvas):
      "Update the display name for “\(canvas.title)”."
    }
  }

  var actionTitle: String {
    switch mode {
    case .create:
      "Create"
    case .duplicate:
      "Duplicate"
    case .rename:
      "Rename"
    }
  }
}

private enum DashboardPolicyCanvasSwitchMutation {
  case activate(TaskBoardPolicyCanvasSummary)
  case create(title: String)
  case duplicate(source: TaskBoardPolicyCanvasSummary, title: String)

  var confirmationMessage: String {
    switch self {
    case .activate(let canvas):
      "Save or discard the current changes before opening “\(canvas.title)”."
    case .create(let title):
      "Save or discard the current changes before creating and opening “\(title)”."
    case .duplicate(let source, let title):
      "Save or discard the current changes before duplicating “\(source.title)” into “\(title)”."
    }
  }
}

private struct DashboardPolicyCanvasDeleteRequest {
  let canvas: TaskBoardPolicyCanvasSummary
  let requiresDirtyResolution: Bool

  var message: String {
    if requiresDirtyResolution {
      return
        "Deleting “\(canvas.title)” will also replace the unsaved edits in the current canvas. Save them first or delete without saving."
    }
    return "Delete “\(canvas.title)”? This cannot be undone."
  }
}
