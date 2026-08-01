import Testing

@testable import HarnessMonitorUIPreviewable

extension TaskBoardRouteContentSourceTests {
  @Test("Dashboard mounts the resizable inspector only while visible")
  func dashboardTaskBoardMountsResizableInspectorOnlyWhileVisible() throws {
    let dashboardSource = try previewableSourceFile(
      domain: "Dashboard",
      named: "DashboardRouteContent.swift"
    )
    let dashboardWindowSource = try previewableSourceFile(
      domain: "Dashboard",
      named: "DashboardWindowView.swift"
    )
    let overviewHostSource = try taskBoardSourceFile(named: "TaskBoardOverviewHost.swift")
    let overviewChromeSource = try taskBoardSourceFile(named: "TaskBoardOverviewView+Chrome.swift")
    let inspectorSource = try taskBoardSourceFile(named: "TaskBoardOperationsInspector.swift")
    let operationsPanelSource = try taskBoardSourceFile(named: "TaskBoardOperationsPanel.swift")
    let dispatchCardSource = try taskBoardSourceFile(
      named: "TaskBoardOperationsDispatchCard.swift"
    )

    #expect(dashboardSource.contains("isRouteVisible: isTaskBoardVisible"))
    #expect(
      dashboardWindowSource.contains(
        "@AppStorage(TaskBoardOperationsInspectorVisibility.storageKey)"
      )
    )
    #expect(
      dashboardWindowSource.contains(
        "private var operationsInspectorVisible = TaskBoardOperationsInspectorVisibility.defaultValue"
      )
    )
    #expect(dashboardWindowSource.contains("TaskBoardOperationsInspector("))
    #expect(
      dashboardWindowSource.contains(
        "@State private var operationsInspectorTriageRulesState ="
      )
    )
    #expect(
      dashboardWindowSource.contains(
        "triageRulesState: operationsInspectorTriageRulesState"
      )
    )
    #expect(dashboardWindowSource.contains("ZStack(alignment: .trailing) {"))
    #expect(
      dashboardWindowSource.contains(
        "if operationsInspectorVisible && route == .taskBoard {"
      )
    )
    #expect(!dashboardSource.contains("HSplitView {"))
    #expect(!dashboardSource.contains("GeometryReader { geometry in"))
    #expect(!dashboardSource.contains("geometry.safeAreaInsets.top"))
    #expect(!dashboardSource.contains(".ignoresSafeArea(.container, edges: .top)"))
    #expect(!dashboardSource.contains("if operationsInspectorVisible {"))
    #expect(!dashboardWindowSource.contains("isVisible: operationsInspectorVisible"))
    #expect(dashboardWindowSource.contains("taskBoardItems: dashboardUI.taskBoardItems"))
    #expect(dashboardSource.contains("showsOperationsPanel: false"))
    #expect(dashboardSource.contains("isCommandFocusActive: isRouteVisible"))
    #expect(dashboardSource.contains("operationsInspectorFocus: operationsInspectorFocus"))
    #expect(
      dashboardWindowSource.contains(
        "operationsInspectorDispatcher.toggleInspector = toggleOperationsInspector"
      )
    )
    #expect(dashboardWindowSource.contains(".onAppear {"))
    #expect(dashboardWindowSource.contains("operationsInspectorVisible.toggle()"))
    #expect(overviewHostSource.contains("showsOperationsPanel: Bool = true"))
    #expect(overviewChromeSource.contains("if taskBoardSessionID == nil, showsOperationsPanel"))
    #expect(inspectorSource.contains("static let defaultValue = false"))
    #expect(inspectorSource.contains("let triageRulesState: TaskBoardTriageRulesEditorState"))
    expectVisibleResizableInspectorSource(inspectorSource)
    #expect(operationsPanelSource.contains("isActive: Bool = true"))
    #expect(operationsPanelSource.contains(".task(id: isActive)"))
    #expect(operationsPanelSource.contains("catch is CancellationError"))
    #expect(dispatchCardSource.contains("isActive ? presentationInput : nil"))
    #expect(dispatchCardSource.contains(".task(id: activePresentationInput)"))
    #expect(dispatchCardSource.contains("guard let activePresentationInput else { return }"))
    #expect(dispatchCardSource.contains("guard isActive else { return false }"))
    #expect(dispatchCardSource.contains("return presentedInput == presentationInput"))
    #expect(dispatchCardSource.contains("isDisabled: !isPresentationCurrent"))
    #expect(dispatchCardSource.contains("presentedInput = input"))
  }

  @Test("Pick Top refreshes policy approvals after its queued request finishes")
  func pickTopRefreshesPolicyApprovals() throws {
    let actionsSource = try taskBoardSourceFile(named: "TaskBoardStepRailView+Actions.swift")

    #expect(actionsSource.contains("HarnessMonitorAsyncWorkQueue.shared.submit("))
    #expect(
      actionsSource.contains(
        "await MainActor.run {\n          state.requestApprovalRefresh()"
          + "\n          state.applyPick(selection)"
      )
    )
  }

  @Test("Dashboard loads policy context through a generation-safe queued operation")
  @MainActor
  func dashboardLoadsPolicyContextThroughSharedQueue() throws {
    let dashboardSource = try previewableSourceFile(
      domain: "Dashboard",
      named: "DashboardRouteContent.swift"
    )
    let state = TaskBoardPolicyWorkspaceLoadState()
    let firstGeneration = try #require(state.beginLoad(hasWorkspace: false))
    state.invalidate()
    let currentGeneration = try #require(state.beginLoad(hasWorkspace: false))
    var appliedGenerations: [UInt64] = []

    state.finishLoad(generation: firstGeneration) {
      appliedGenerations.append(firstGeneration)
    }
    #expect(state.isLoading)
    #expect(appliedGenerations.isEmpty)
    state.finishLoad(generation: currentGeneration) {
      appliedGenerations.append(currentGeneration)
    }
    #expect(!state.isLoading)
    #expect(appliedGenerations == [currentGeneration])
    #expect(dashboardSource.contains("HarnessMonitorAsyncWorkQueue.shared.submit("))
    #expect(
      dashboardSource.contains("await store.loadTaskBoardPolicyWorkspaceSnapshot()")
    )
    #expect(!dashboardSource.contains("ensurePolicyCanvasWorkspaceLoadedForRuntimePolicies"))
    #expect(dashboardSource.contains("store.adoptTaskBoardPolicyWorkspaceSnapshot(workspace)"))
    #expect(dashboardSource.contains(".onChange(of: isRouteVisible, initial: true)"))
  }

  @Test("Task board lanes render every card instead of hiding overflow")
  func taskBoardLanesRenderEveryCardInsteadOfHidingOverflow() throws {
    let unifiedSource = try taskBoardSourceFile(named: "TaskBoardLaneUnifiedColumn.swift")
    let laneSupportSource = try taskBoardSourceFile(named: "TaskBoardLaneSupport.swift")

    #expect(unifiedSource.contains("decisions.map(TaskBoardLaneListRow.decision)"))
    #expect(unifiedSource.contains("displayAPIItems.map(TaskBoardLaneListRow.api)"))
    #expect(unifiedSource.contains("inboxItems.map(TaskBoardLaneListRow.inbox)"))
    #expect(unifiedSource.contains("ForEach(displayLaneListRows)"))
    #expect(!unifiedSource.contains(".prefix(5)"))
    #expect(!unifiedSource.contains(".prefix(4)"))
    #expect(!unifiedSource.contains("TaskBoardLaneOverflowRow("))
    #expect(!laneSupportSource.contains("TaskBoardLaneOverflowRow"))
  }

}
