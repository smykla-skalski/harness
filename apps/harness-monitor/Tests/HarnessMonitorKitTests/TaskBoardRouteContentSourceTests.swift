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
    let managementHierarchySource = try taskBoardSourceFile(
      named: "TaskBoardItemManagementPanel+Hierarchy.swift"
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
    let actionsSource = try previewableTypeSource(
      domain: "TaskBoard",
      type: "TaskBoardOverviewActions"
    )

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
    #expect(selectionModelSource.contains("selectAPIItem(item)"))
    #expect(managementHierarchySource.contains("selectionModel.selectAPIItem(item)"))
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
    let listTunerSource = try taskBoardSourceFile(named: "TaskBoardNativeListTuner.swift")
    let dragRuntimeSource = try taskBoardSourceFile(named: "TaskBoardCardDragRuntime.swift")
    let laneSupportSource = try taskBoardSourceFile(named: "TaskBoardLaneSupport.swift")
    let boardSource = try taskBoardSourceFile(named: "TaskBoardOverviewView+Board.swift")

    #expect(overviewSource.contains("lane.taskBoardDropStatus"))
    #expect(dragSource.contains("TaskBoardCardDragPayload"))
    #expect(dragSource.contains("CodableRepresentation(contentType: .harnessMonitorTaskBoardCard)"))
    #expect(laneDropSource.contains("TaskBoardCardDropPlan"))
    #expect(laneDropSource.contains("items.allSatisfy"))
    #expect(laneSource.contains(".draggable(containerItemID: cardID)"))
    #expect(!laneSource.contains(".onDrag {"))
    #expect(!laneSource.contains("TaskBoardCardPill(label: item.status.title"))
    #expect(!laneSource.contains("DragPreviewCard"))
    #expect(unifiedSource.contains("for: TaskBoardCardDragPayload.self"))
    #expect(unifiedSource.contains("List {"))
    #expect(unifiedSource.contains("private var droppableListRowsContent: some DynamicViewContent"))
    #expect(unifiedSource.contains("ForEach(displayLaneListRows)"))
    #expect(unifiedSource.contains("indexed-destination"))
    #expect(unifiedSource.contains(".introspect(.list, on: .macOS(.v26))"))
    #expect(unifiedSource.contains("nativeListCoordinator.register(tableView, lane: lane)"))
    #expect(listTunerSource.contains("draggingDestinationFeedbackStyle = .none"))
    #expect(listTunerSource.contains("setGapTarget(nil, reason: \"before-model-mutation\")"))
    #expect(dragRuntimeSource.contains("final class TaskBoardCardDragRuntime"))
    #expect(listTunerSource.contains("tableView.scrollRowToVisible(row)"))
    #expect(
      unifiedSource.contains(
        "TaskBoardCardDragDiagnostics.recordDropSession(session, lane: lane.rawValue)"
      )
    )
    #expect(!unifiedSource.contains(".taskBoardCardReorderDropTarget("))
    #expect(!unifiedSource.contains(".onDrop("))
    #expect(!unifiedSource.contains("let dragPayload:"))
    #expect(
      laneSupportSource.contains(
        """
        lineWidth: cardStrokeWidth
                  )
                  .allowsHitTesting(false)
        """
      )
    )
    #expect(boardSource.contains(".dragContainerSelection("))
    #expect(boardSource.contains(".dragContainer("))
    #expect(!laneSource.contains("TaskBoardItemDragPayload"))
    #expect(!laneSource.contains("TaskBoardInboxItemDragPayload"))
  }

  @Test("Task board task cards select on click and open on double click")
  func taskBoardTaskCardsSelectOnClickAndOpenOnDoubleClick() throws {
    let laneSource = try taskBoardSourceFile(named: "TaskBoardLaneViews.swift")
    let supportSource = try taskBoardSourceFile(named: "TaskBoardCardSelection.swift")

    #expect(
      laneSource.contains("selectionModel.select(cardID, modifiers: Self.currentEventModifiers)"))
    #expect(laneSource.contains("Self.currentClickCount == 2"))
    #expect(!laneSource.contains("TapGesture(count: 2)"))
    #expect(laneSource.contains(".accessibilityAddTraits(isSelected ? .isSelected : [])"))
    #expect(laneSource.contains("Button(\"Open\")"))
    #expect(laneSource.contains("Button(\"Open Spawned Task\")"))
    #expect(laneSource.contains("selectionModel.openAPIItem(item, actions: actions)"))
    #expect(laneSource.contains("actions.openSpawnedTask(item, openWindow: openWindow)"))
    #expect(supportSource.contains("SessionSidebarMultiSelect.resolve("))
  }

  @Test("Task board custom selection replaces the native rectangular focus effect")
  func taskBoardCustomSelectionReplacesNativeRectangularFocusEffect() throws {
    let supportSource = try taskBoardSourceFile(named: "TaskBoardLaneSupport.swift")
    let laneSource = try taskBoardSourceFile(named: "TaskBoardLaneUnifiedColumn.swift")

    #expect(supportSource.contains(".focusEffectDisabled(isSelected)"))
    #expect(supportSource.contains("if isSelected {"))
    #expect(supportSource.contains("isSelected ? 2"))
    #expect(!laneSource.contains(".selectionDisabled()"))
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
    #expect(!unifiedSource.contains(".contextMenu {"))
    #expect(unifiedSource.contains(".background {"))
    #expect(unifiedSource.contains("TaskBoardCardContextMenu(cardID: cardID"))
    #expect(
      contextMenuSource.contains(
        "struct TaskBoardCardContextMenu: NSViewRepresentable"
      )
    )
    #expect(contextMenuSource.contains("NSClickGestureRecognizer("))
    #expect(contextMenuSource.contains("recognizer.buttonMask = 0x2"))
    #expect(contextMenuSource.contains("recognizer.buttonMask = 0x1"))
    #expect(contextMenuSource.contains("recognizer.delaysSecondaryMouseButtonEvents = true"))
    #expect(contextMenuSource.contains("recognizer.delaysPrimaryMouseButtonEvents = true"))
    #expect(contextMenuSource.contains("cell.focusRingType = .none"))
    #expect(contextMenuSource.contains("NSMenu.popUpContextMenu("))
    #expect(contextMenuSource.contains("TaskBoardCardContextMenuScope.resolve("))
    #expect(contextMenuSource.contains("actions.primeSelection(scope.cardIDs)"))
    #expect(contextMenuSource.contains("\"Open Spawned Task\""))
    #expect(!contextMenuSource.contains("let _: Task"))
    #expect(contextMenuSource.contains("actions.githubURL(scope.primaryID) != nil"))
    #expect(
      contextMenuSource.contains(
        "title: \"Open on GitHub\","
      )
    )
    #expect(contextMenuSource.contains("symbol: \"arrow.up.right.square\""))
    #expect(contextMenuSource.contains("actions.openGitHubURL(url)"))
    #expect(contextMenuActionsSource.contains("githubURL: githubURL"))
    #expect(contextMenuActionsSource.contains("openURL(url)"))
    #expect(overviewViewSource.contains("@Environment(\\.openURL)"))
    #expect(contextMenuSource.contains("NSMenuItem(title: \"Move to...\""))
    #expect(contextMenuSource.contains("actions.move($0.primaryID, $0.cardIDs, lane)"))
    #expect(contextMenuSource.contains("if scope.isSingle, case .api = scope.primaryID"))
    #expect(contextMenuSource.contains("\"Move to Top\""))
    #expect(contextMenuSource.contains("\"Move to Bottom\""))
    #expect(contextMenuSource.contains("actions.moveToEdge($0.primaryID, edge)"))
    #expect(contextMenuSource.contains("actions.canMoveToEdge(scope.primaryID, edge)"))
    #expect(contextMenuActionsSource.contains("canMoveToEdge: canMoveCardContextMenuItemToEdge"))
    #expect(contextMenuActionsSource.contains("moveToEdge: moveCardContextMenuItemToEdge"))
    #expect(contextMenuActionsSource.contains("actions.reorderTaskBoardItem("))
    #expect(contextMenuActionsSource.contains("sourceStatus: context.item.status"))
    #expect(contextMenuActionsSource.contains("destinationStatus: context.item.status"))
    #expect(contextMenuActionsSource.contains("canonicalItems: allKnownTaskBoardItems"))
    #expect(
      !contextMenuActionsSource.contains(
        "currentPresentation.apiItems(in: lane).map(\\.id)"
      )
    )
    #expect(
      contextMenuSource.contains(
        "for lane in TaskBoardInboxLane.allCases where lane != .umbrella"
      )
    )
    #expect(contextMenuSource.contains("title: scope.deleteLabel,"))
    #expect(contextMenuSource.contains("actions.canDelete(scope.cardIDs)"))
    #expect(contextMenuSource.contains("actions.deleteTargets?(targets)"))
    #expect(!laneSource.contains(".contextMenu"))
  }

  @Test("Task board card context menu edge actions detect reached lane edges")
  func taskBoardCardContextMenuEdgeActionsDetectReachedEdges() {
    let orderedItemIDs = ["first", "middle", "last"]

    #expect(
      TaskBoardCardContextMenuEdge.top.isCurrentEdge(
        itemID: "first",
        orderedItemIDs: orderedItemIDs
      )
    )
    #expect(
      !TaskBoardCardContextMenuEdge.top.isCurrentEdge(
        itemID: "middle",
        orderedItemIDs: orderedItemIDs
      )
    )
    #expect(
      TaskBoardCardContextMenuEdge.bottom.isCurrentEdge(
        itemID: "last",
        orderedItemIDs: orderedItemIDs
      )
    )
    #expect(
      !TaskBoardCardContextMenuEdge.bottom.isCurrentEdge(
        itemID: "middle",
        orderedItemIDs: orderedItemIDs
      )
    )
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

  @Test("Task board lanes highlight the active native drop target")
  func taskBoardLanesHighlightTheActiveNativeDropTarget() throws {
    let unifiedSource = try taskBoardSourceFile(named: "TaskBoardLaneUnifiedColumn.swift")
    let dragRuntimeSource = try taskBoardSourceFile(named: "TaskBoardCardDragRuntime.swift")
    let laneChromeSource = try taskBoardSourceFile(named: "TaskBoardLaneChrome.swift")

    #expect(!unifiedSource.contains("@State private var isDropTargeted"))
    #expect(unifiedSource.contains(".onDropSessionUpdated(handleLaneDropSession)"))
    #expect(unifiedSource.contains("TaskBoardLaneDropHighlight("))
    #expect(unifiedSource.contains("dragRuntime.setTargeted(targeted, lane: lane)"))
    #expect(dragRuntimeSource.contains("final class TaskBoardLaneDropHighlightState"))
    #expect(laneChromeSource.contains("state.isTargeted"))
    #expect(unifiedSource.contains("taskBoardLaneIsDropTargeted("))
  }

  @Test("Accepted task moves use a native List reader to reveal the card after layout")
  func acceptedTaskMovesUseTypedNativeListScrollingToRevealTheCard() throws {
    let overviewSource = try taskBoardSourceFile(named: "TaskBoardOverviewView.swift")
    let boardSource = try taskBoardSourceFile(named: "TaskBoardOverviewView+Board.swift")
    let laneSource = try taskBoardSourceFile(named: "TaskBoardLaneUnifiedColumn.swift")
    let revealSource = try taskBoardSourceFile(
      named: "TaskBoardLaneUnifiedColumn+Reveal.swift"
    )
    let listTunerSource = try taskBoardSourceFile(named: "TaskBoardNativeListTuner.swift")
    let contextMenuSource = try taskBoardSourceFile(
      named: "TaskBoardOverviewView+ContextMenu.swift"
    )
    let dropSource = try taskBoardSourceFile(named: "TaskBoardOverviewView+BoardDrop.swift")
    let collapseSource = try taskBoardSourceFile(named: "TaskBoardOverviewView+LaneCollapse.swift")

    #expect(
      overviewSource.contains(
        "@State private var laneRevealCoordinator = TaskBoardLaneRevealCoordinator()"
      )
    )
    #expect(boardSource.contains("revealCoordinator: laneRevealCoordinatorValue"))
    #expect(laneSource.contains(".task(id: actionableRevealRequest)"))
    #expect(revealSource.contains("await nativeListCoordinator.reveal(row: row, in: lane)"))
    #expect(revealSource.contains("revealCoordinator.consume(request)"))
    #expect(revealSource.contains("revealCoordinator.retry(request)"))
    #expect(listTunerSource.contains("tableView.scrollRowToVisible(row)"))
    #expect(contextMenuSource.contains("requestLaneReveal("))
    #expect(dropSource.contains("requestLaneReveal("))
    #expect(collapseSource.contains("TaskBoardLaneCollapsePreferences.expandedRawValue("))

    for source in [laneSource, contextMenuSource, dropSource, collapseSource] {
      #expect(!source.contains("DispatchQueue.main"))
      #expect(!source.contains("Task.sleep"))
      #expect(!source.contains("Task.yield"))
    }
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

  @Test("Dashboard retains mounted route state without retaining Reviews publishers")
  func dashboardRetainsMountedAuxiliaryRouteState() throws {
    let dashboardSource = try previewableSourceFile(
      domain: "Dashboard",
      named: "DashboardRouteContent.swift"
    )
    let dashboardWindowSource = try previewableSourceFile(
      domain: "Dashboard",
      named: "DashboardWindowView.swift"
    )
    let policyCanvasSource = try previewableSourceFile(
      domain: "Dashboard",
      named: "DashboardPolicyCanvasRouteView.swift"
    )

    #expect(dashboardSource.contains("DashboardRetainedRouteLayout(selectedRoute: route)"))
    #expect(dashboardSource.contains("private struct DashboardRetainedAuxiliaryRoute"))
    #expect(dashboardSource.contains("@State private var hasBeenMounted = false"))
    #expect(dashboardSource.contains("private var isAuditVisible"))
    #expect(dashboardSource.contains("private var isDiagnosticsVisible"))
    #expect(dashboardSource.contains("private var isDebuggingVisible"))
    #expect(dashboardSource.contains("private var isPolicyCanvasVisible"))
    #expect(dashboardSource.contains("private var isReviewsVisible"))
    #expect(
      dashboardSource.contains(
        "DashboardRetainedAuxiliaryRoute(isVisible: isAuditVisible)"
      )
    )
    #expect(
      dashboardSource.contains(
        "DashboardRetainedAuxiliaryRoute(isVisible: isPolicyCanvasVisible)"
      )
    )
    #expect(
      dashboardSource.contains(
        "DashboardRetainedAuxiliaryRoute(isVisible: isDiagnosticsVisible)"
      )
    )
    #expect(
      dashboardSource.contains(
        "DashboardRetainedAuxiliaryRoute(isVisible: isDebuggingVisible)"
      )
    )
    #expect(dashboardSource.contains("if hasBeenMounted || isVisible"))
    #expect(dashboardSource.contains(".opacity(isVisible ? 1 : 0)"))
    #expect(dashboardSource.contains(".allowsHitTesting(isVisible)"))
    #expect(dashboardSource.contains(".accessibilityHidden(!isVisible)"))
    #expect(dashboardSource.contains("policyCanvasViewModelStore: policyCanvasViewModelStore"))
    #expect(
      dashboardWindowSource.contains(
        "@StateObject private var policyCanvasViewModelStore"
      )
    )
    #expect(
      policyCanvasSource.contains(
        "@ObservedObject private var policyCanvasViewModelStore"
      )
    )
    #expect(dashboardSource.contains("if isReviewsVisible {"))
    #expect(
      !dashboardSource.contains(
        "DashboardRetainedAuxiliaryRoute(isVisible: isReviewsVisible)"
      )
    )
    #expect(!dashboardSource.contains("selectedAuxiliaryRoute"))
  }

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

}
