import Foundation
import Testing

@testable import HarnessMonitorUIPreviewable

@Suite("Task board route content source")
struct TaskBoardRouteContentSourceTests {
  @Test("Board-only task board items open in a management sheet")
  func boardOnlyTaskBoardItemsHaveManagementSurface() throws {
    let overviewSource = try taskBoardOverviewSource()
    let managementPanelSource = try taskBoardSourceFile(named: "TaskBoardItemManagementPanel.swift")
    let managementActionsSource = try taskBoardSourceFile(
      named: "TaskBoardItemLiveActionButtons.swift"
    )
    let managementComponentsSource = try taskBoardSourceFile(
      named: "TaskBoardItemManagementPanel+Components.swift"
    )
    let inlineTextFieldSource = try previewableSourceFile(
      domain: "Shared",
      named: "HarnessMonitorInlineTextField.swift"
    )
    let managementSupportSource = try taskBoardSourceFile(
      named: "TaskBoardItemManagementSupport.swift"
    )
    let laneSource = try taskBoardSourceFile(named: "TaskBoardLaneViews.swift")
    let selectionModelSource = try taskBoardSourceFile(named: "TaskBoardCardSelectionModel.swift")
    let actionsSource = try taskBoardSourceFile(named: "TaskBoardOverviewActions.swift")

    #expect(overviewSource.contains("TaskBoardItemManagementPanel("))
    #expect(overviewSource.contains(".sheet(item: taskBoardManagementSheet)"))
    #expect(managementPanelSource.contains("harness.task-board.manage-item"))
    #expect(
      managementActionsSource.contains(
        "TaskBoardOverviewItemBehavior.runOnceRequest(for: item, dryRun: runOnceDryRun)"
      )
    )
    #expect(actionsSource.contains("evaluateTaskBoardItem(item)"))
    #expect(!overviewSource.contains("if !item.hasLinkedSessionTask"))
    #expect(selectionModelSource.contains("TaskBoardOverviewItemBehavior.selectionAction("))
    #expect(overviewSource.contains("let inboxItems = currentPresentation.inboxItems(in: lane)"))
    #expect(managementPanelSource.contains("Session Task"))
    #expect(managementPanelSource.contains("Board Only"))
    #expect(managementPanelSource.contains("TaskBoardManagementFacts("))
    #expect(managementPanelSource.contains("TaskBoardDescriptionSection("))
    #expect(managementPanelSource.contains("TaskBoardExternalLinks("))
    #expect(managementPanelSource.contains(".harnessDismissButtonStyle()"))
    #expect(managementPanelSource.contains("xmark.circle.fill"))
    #expect(!managementPanelSource.contains(".harnessAccessoryButtonStyle(tint: .secondary)"))
    #expect(
      managementPanelSource.contains(
        "HarnessMonitorTextSize.scaledFont(.title2.weight(.semibold), by: fontScale)"))
    #expect(managementComponentsSource.contains("HarnessMonitorInlineTextField("))
    #expect(managementComponentsSource.contains("showsClearButton: false"))
    #expect(managementComponentsSource.contains("hasVisibleLabel: true"))
    #expect(managementComponentsSource.contains(".pickerStyle(.menu)"))
    #expect(managementComponentsSource.contains("struct TaskBoardManagementMultilineField"))
    #expect(inlineTextFieldSource.contains("struct HarnessMonitorInlineMultilineTextField"))
    #expect(overviewSource.contains(".padding(HarnessMonitorTheme.spacingLG)"))
    #expect(managementSupportSource.contains("Link(destination: destination.url)"))
    #expect(managementSupportSource.contains("Text(\"Description\")"))
    #expect(!managementSupportSource.contains("#if HARNESS_FEATURE_" + "TEXTUAL"))
    #expect(managementSupportSource.contains("HarnessMonitorSegmentedPicker("))
    #expect(managementSupportSource.contains("HarnessMonitorMarkdownText("))
    #expect(managementSupportSource.contains("TaskBoardDescriptionEditor("))
    #expect(managementSupportSource.contains("HarnessMonitorInlineMultilineTextField("))
    #expect(managementSupportSource.contains("hasVisibleLabel: true"))
    #expect(managementSupportSource.contains("maxHeight: minHeight"))
    #expect(managementSupportSource.contains("harness.task-board.manage-item.body-preview"))
    #expect(managementActionsSource.contains("Evaluate Item Live"))
    #expect(managementActionsSource.contains("Preview Run Once"))
    #expect(managementActionsSource.contains(".confirmationDialog("))
    #expect(managementPanelSource.contains("TaskBoardPlanLifecycleActionButtons("))
    #expect(!managementPanelSource.contains("metrics.managementPanelCornerRadius"))
    #expect(managementSupportSource.contains("Label(\"Begin Plan\""))
    #expect(managementSupportSource.contains("Label(\"Submit Plan\""))
    #expect(managementSupportSource.contains("Label(\"Approve Plan\""))
    #expect(!laneSource.contains(".disabled(!isOpenable)"))
    #expect(!laneSource.contains("private var isOpenable"))
  }

  @Test("Task board lanes expose card drag and lane drop")
  func taskBoardLanesExposeCardDragAndLaneDrop() throws {
    let overviewSource = try taskBoardOverviewSource()
    let laneSource = try taskBoardSourceFile(named: "TaskBoardLaneViews.swift")
    let laneDropSource = try taskBoardSourceFile(named: "TaskBoardLaneDropSupport.swift")
    let dragSource = try taskBoardSourceFile(named: "TaskBoardCardDragSupport.swift")
    let unifiedSource = try taskBoardSourceFile(named: "TaskBoardLaneUnifiedColumn.swift")
    let boardSource = try taskBoardSourceFile(named: "TaskBoardOverviewView+Board.swift")

    #expect(overviewSource.contains("lane.taskBoardDropStatus"))
    #expect(dragSource.contains("TaskBoardCardDragPayload"))
    #expect(laneDropSource.contains("TaskBoardCardDropPlan"))
    #expect(laneDropSource.contains("items.allSatisfy"))
    #expect(laneSource.contains(".draggable(containerItemID: cardID)"))
    #expect(!laneSource.contains(".onDrag {"))
    #expect(!laneSource.contains("TaskBoardCardPill(label: item.status.title"))
    #expect(!laneSource.contains("DragPreviewCard"))
    #expect(unifiedSource.contains("for: TaskBoardCardDragPayload.self"))
    #expect(unifiedSource.contains("isEnabled: isDropEnabled"))
    #expect(unifiedSource.contains("session: DropSession"))
    #expect(unifiedSource.contains(".dropConfiguration(dropConfiguration)"))
    #expect(unifiedSource.contains(".onDropSessionUpdated(updateDropSession)"))
    #expect(unifiedSource.contains("? .move : .forbidden"))
    #expect(unifiedSource.contains("isDropEnabled && isDropCandidate"))
    #expect(unifiedSource.contains("TaskBoardCardDropPlan.resolve(payloads, to: lane)"))
    #expect(!unifiedSource.contains(".onDrop("))
    #expect(!unifiedSource.contains("let dragPayload:"))
    #expect(boardSource.contains(".dragContainerSelection("))
    #expect(boardSource.contains(".dragContainer("))
    #expect(!laneSource.contains("TaskBoardItemDragPayload"))
    #expect(!laneSource.contains("TaskBoardInboxItemDragPayload"))
  }

  @Test("Task board task cards select on click and open on double click")
  func taskBoardTaskCardsSelectOnClickAndOpenOnDoubleClick() throws {
    let laneSource = try taskBoardSourceFile(named: "TaskBoardLaneViews.swift")
    let supportSource = try taskBoardSourceFile(named: "TaskBoardCardSelection.swift")

    #expect(laneSource.contains("selectionModel.select(cardID, modifiers: Self.currentEventModifiers)"))
    #expect(laneSource.contains("Self.currentClickCount == 2"))
    #expect(!laneSource.contains("TapGesture(count: 2)"))
    #expect(laneSource.contains(".accessibilityAddTraits(isSelected ? .isSelected : [])"))
    #expect(supportSource.contains("SessionSidebarMultiSelect.resolve("))
  }

  @Test("Task board cards expose one selection-aware context menu per card")
  func taskBoardCardsExposeSelectionAwareContextMenus() throws {
    let boardSource = try taskBoardSourceFile(named: "TaskBoardOverviewView+Board.swift")
    let contextMenuSource = try taskBoardSourceFile(
      named: "TaskBoardCardContextMenu.swift"
    )
    let contextMenuActionsSource = try taskBoardSourceFile(
      named: "TaskBoardOverviewView+ContextMenu.swift"
    )
    let overviewViewSource = try taskBoardSourceFile(named: "TaskBoardOverviewView.swift")
    let laneSource = try taskBoardSourceFile(named: "TaskBoardLaneViews.swift")
    let unifiedSource = try taskBoardSourceFile(named: "TaskBoardLaneUnifiedColumn.swift")

    #expect(
      !boardSource.contains(".contextMenu(forSelectionType: TaskBoardCardID.self)")
    )
    #expect(unifiedSource.contains(".contextMenu {"))
    #expect(unifiedSource.contains("TaskBoardCardContextMenu(cardID: cardID"))
    #expect(contextMenuSource.contains("TaskBoardCardContextMenuScope.resolve("))
    #expect(contextMenuSource.contains(".onAppear {"))
    #expect(contextMenuSource.contains("actions.primeSelection(scope.cardIDs)"))
    #expect(!contextMenuSource.contains("let _: Task"))
    #expect(contextMenuSource.contains("if let githubURL = actions.githubURL(scope.primaryID)"))
    #expect(
      contextMenuSource.contains(
        "Label(\"Open on GitHub\", systemImage: \"arrow.up.right.square\")"
      )
    )
    #expect(contextMenuSource.contains("actions.openGitHubURL(githubURL)"))
    #expect(contextMenuActionsSource.contains("githubURL: githubURL"))
    #expect(contextMenuActionsSource.contains("openURL(url)"))
    #expect(overviewViewSource.contains("@Environment(\\.openURL)"))
    #expect(contextMenuSource.contains("Menu(\"Move to...\")"))
    #expect(contextMenuSource.contains("ForEach(TaskBoardInboxLane.allCases)"))
    #expect(contextMenuSource.contains("Button(scope.deleteLabel, role: .destructive)"))
    #expect(contextMenuSource.contains("!actions.canDelete(scope.cardIDs)"))
    #expect(contextMenuSource.contains("actions.deleteTargets?(targets)"))
    #expect(!laneSource.contains(".contextMenu"))
  }

  @Test("Task board lanes keep board column chrome")
  func taskBoardLanesKeepBoardColumnChrome() throws {
    let unifiedSource = try taskBoardSourceFile(named: "TaskBoardLaneUnifiedColumn.swift")
    let laneChromeSource = try taskBoardSourceFile(named: "TaskBoardLaneChrome.swift")
    let overviewSource = try taskBoardSourceFile(named: "TaskBoardOverviewView.swift")

    #expect(unifiedSource.contains(".taskBoardLaneColumnChrome("))
    #expect(laneChromeSource.contains("private struct TaskBoardLaneColumnChrome"))
    #expect(laneChromeSource.contains("private var laneSurfaceFill: Color"))
    #expect(laneChromeSource.contains("RoundedRectangle(cornerRadius: metrics.cardCornerRadius"))
    #expect(laneChromeSource.contains(".strokeBorder(laneStrokeColor, lineWidth: laneStrokeWidth)"))
    #expect(laneChromeSource.contains("private var laneStrokeColor: Color"))
    #expect(laneChromeSource.contains("private var laneStrokeWidth: CGFloat"))
    #expect(!overviewSource.contains("Board-owned work awaiting progression."))
    #expect(!overviewSource.contains("Open work pulled from active sessions."))
  }

  @Test("Task board lanes expand beyond the fixed baseline when the dashboard is taller")
  func taskBoardLanesExpandBeyondFixedBaselineWhenDashboardIsTaller() throws {
    let dashboardSource = try previewableSourceFile(
      domain: "Dashboard",
      named: "DashboardRouteContent.swift"
    )
    let overviewHostSource = try taskBoardSourceFile(named: "TaskBoardOverviewHost.swift")
    let overviewSource = try taskBoardSourceFile(named: "TaskBoardOverviewView.swift")
    let overviewSupportSource = try taskBoardSourceFile(named: "TaskBoardOverviewSupport.swift")
    let laneChromeSource = try taskBoardSourceFile(named: "TaskBoardLaneChrome.swift")

    #expect(dashboardSource.contains("dashboardExpandedContent"))
    #expect(dashboardSource.contains("GeometryReader { proxy in"))
    #expect(dashboardSource.contains("ScrollView(.vertical)"))
    #expect(dashboardSource.contains("TaskBoardDashboardViewportLayout"))
    #expect(dashboardSource.contains(".scrollBounceBehavior(.basedOnSize)"))
    #expect(overviewHostSource.contains("fillsAvailableHeight: scope.fillsAvailableHeight"))
    #expect(overviewSource.contains("fillsAvailableHeight ? .infinity : nil"))
    #expect(overviewSupportSource.contains("struct TaskBoardDashboardViewportLayout: Layout"))
    #expect(overviewSupportSource.contains("max(intrinsic.height, max(viewportHeight, 0))"))
    #expect(!overviewSupportSource.contains("TaskBoardFillLastLayout"))
    #expect(!overviewSupportSource.contains("usesProposedHeightForMeasurement"))
    #expect(
      overviewSupportSource.contains("let height = max(measuredHeight, proposal.height ?? 0)"))
    #expect(laneChromeSource.contains("idealHeight: metrics.laneFixedHeight"))
    #expect(laneChromeSource.contains("minHeight: metrics.laneFixedHeight"))
    #expect(laneChromeSource.contains("maxHeight: .infinity"))
  }

  @Test("Dashboard retains visited routes without laying out hidden ones")
  func dashboardRetainsRoutesWithoutHiddenLayout() throws {
    let dashboardSource = try previewableSourceFile(
      domain: "Dashboard",
      named: "DashboardRouteContent.swift"
    )

    #expect(dashboardSource.contains("DashboardRetainedRouteLayout(selectedRoute: route)"))
    #expect(
      dashboardSource.contains(
        ".layoutValue(key: DashboardRetainedRouteKey.self, value: .taskBoard)"
      )
    )
    #expect(
      dashboardSource.contains(
        ".layoutValue(key: DashboardRetainedRouteKey.self, value: .policyCanvas)"
      )
    )
    #expect(
      dashboardSource.contains(".layoutValue(key: DashboardRetainedRouteKey.self, value: .reviews)")
    )
    #expect(dashboardSource.contains("private struct DashboardRetainedRouteLayout: Layout"))
    #expect(dashboardSource.contains("selectedSubview(in: subviews)?.place("))
    #expect(dashboardSource.contains(".allowsHitTesting(isPolicyCanvasVisible)"))
    #expect(dashboardSource.contains(".accessibilityHidden(!isPolicyCanvasVisible)"))
  }

  @Test("Dashboard task board moves operations into a collapsed retained inspector")
  func dashboardTaskBoardMovesOperationsIntoCollapsedRetainedInspector() throws {
    let dashboardSource = try previewableSourceFile(
      domain: "Dashboard",
      named: "DashboardRouteContent.swift"
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
      dashboardSource.contains(
        "@AppStorage(TaskBoardOperationsInspectorVisibility.storageKey)"
      )
    )
    #expect(
      dashboardSource.contains(
        "private var operationsInspectorVisible = TaskBoardOperationsInspectorVisibility.defaultValue"
      )
    )
    #expect(dashboardSource.contains("TaskBoardOperationsInspector("))
    #expect(!dashboardSource.contains("if operationsInspectorVisible {"))
    #expect(
      dashboardSource.contains(
        "isVisible: operationsInspectorVisible && isRouteVisible"
      )
    )
    #expect(dashboardSource.contains("taskBoardItems: dashboardUI.taskBoardItems"))
    #expect(dashboardSource.contains("showsOperationsPanel: false"))
    #expect(dashboardSource.contains("isCommandFocusActive: isRouteVisible"))
    #expect(dashboardSource.contains("operationsInspectorFocus: operationsInspectorFocus"))
    #expect(
      dashboardSource.contains(
        "operationsInspectorDispatcher.toggleInspector = toggleOperationsInspector"
      )
    )
    #expect(dashboardSource.contains(".onAppear {"))
    #expect(dashboardSource.contains("operationsInspectorVisible.toggle()"))
    #expect(overviewHostSource.contains("showsOperationsPanel: Bool = true"))
    #expect(overviewChromeSource.contains("if taskBoardSessionID == nil, showsOperationsPanel"))
    #expect(inspectorSource.contains("static let defaultValue = false"))
    #expect(inspectorSource.contains("private static let width: CGFloat = 380"))
    #expect(inspectorSource.contains("ScrollView(.vertical)"))
    #expect(inspectorSource.contains("TaskBoardOperationsPanel("))
    #expect(inspectorSource.contains("taskBoardItems: isVisible ? taskBoardItems : []"))
    #expect(inspectorSource.contains("isActive: isVisible"))
    #expect(inspectorSource.contains(".frame(width: isVisible ? Self.width : 0"))
    #expect(inspectorSource.contains(".allowsHitTesting(isVisible)"))
    #expect(inspectorSource.contains(".accessibilityHidden(!isVisible)"))
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
          + "\n          state.pickedSelection = selection"
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

    #expect(unifiedSource.contains("ForEach(apiItems)"))
    #expect(unifiedSource.contains("ForEach(inboxItems)"))
    #expect(unifiedSource.contains("ForEach(decisions, id: \\.id)"))
    #expect(!unifiedSource.contains(".prefix(5)"))
    #expect(!unifiedSource.contains(".prefix(4)"))
    #expect(!unifiedSource.contains("TaskBoardLaneOverflowRow("))
    #expect(!laneSupportSource.contains("TaskBoardLaneOverflowRow"))
  }

  private func taskBoardSourceFile(named relativePath: String) throws -> String {
    try previewableSourceFile(domain: "TaskBoard", named: relativePath)
  }

  private func taskBoardOverviewSource() throws -> String {
    try [
      taskBoardSourceFile(named: "TaskBoardOverviewView.swift"),
      taskBoardSourceFile(named: "TaskBoardOverviewView+Support.swift"),
      taskBoardSourceFile(named: "TaskBoardOverviewLiveOperations.swift"),
      taskBoardSourceFile(named: "TaskBoardOverviewView+Board.swift"),
      taskBoardSourceFile(named: "TaskBoardOverviewView+CardInteraction.swift"),
    ].joined(separator: "\n")
  }

  private func previewableSourceFile(domain: String, named relativePath: String) throws -> String {
    let testsDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    let repoRoot =
      testsDirectory
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
    let fileURL =
      repoRoot
      .appendingPathComponent("apps/harness-monitor/Sources/HarnessMonitorUIPreviewable")
      .appendingPathComponent("Views")
      .appendingPathComponent(domain)
      .appendingPathComponent(relativePath)
    return try String(contentsOf: fileURL, encoding: .utf8)
  }
}
