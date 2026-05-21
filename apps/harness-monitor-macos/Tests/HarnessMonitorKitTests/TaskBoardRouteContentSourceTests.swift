import Foundation
import Testing

@testable import HarnessMonitorUIPreviewable

@Suite("Task board route content source")
struct TaskBoardRouteContentSourceTests {
  @Test("Board-only task board items open in a management sheet")
  func boardOnlyTaskBoardItemsHaveManagementSurface() throws {
    let overviewSource = try taskBoardOverviewSource()
    let managementPanelSource = try taskBoardSourceFile(named: "TaskBoardItemManagementPanel.swift")
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

    #expect(overviewSource.contains("TaskBoardItemManagementPanel("))
    #expect(overviewSource.contains(".sheet(item: taskBoardManagementSheet)"))
    #expect(managementPanelSource.contains("harness.task-board.manage-item"))
    #expect(overviewSource.contains("TaskBoardOverviewItemBehavior.runOnceRequest(for: item)"))
    #expect(overviewSource.contains("onEvaluateTaskBoardItem(item)"))
    #expect(!overviewSource.contains("if !item.hasLinkedSessionTask"))
    #expect(overviewSource.contains("TaskBoardOverviewItemBehavior.selectionAction("))
    #expect(overviewSource.contains("inboxItems: cachedPresentation.inboxItems(in: lane)"))
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
    #expect(managementPanelSource.contains("Evaluate Item"))
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
    let unifiedSource = try taskBoardSourceFile(named: "TaskBoardLaneUnifiedColumn.swift")

    #expect(overviewSource.contains("lane.taskBoardDropStatus"))
    #expect(laneSource.contains("TaskBoardItemDragPayload"))
    #expect(laneSource.contains("TaskBoardInboxItemDragPayload"))
    #expect(laneSource.contains("let status: TaskBoardStatus"))
    #expect(unifiedSource.contains("TaskBoardLaneDropPolicy.moveFirstPayload("))
    #expect(unifiedSource.contains("TaskBoardInboxDropPolicy.moveFirstPayload("))
    #expect(laneDropSource.contains("TaskBoardInboxDropPolicy"))
    #expect(laneDropSource.contains("sourceLane != destination"))
    #expect(laneSource.contains(".draggable(dragPayload)"))
    #expect(laneSource.contains(".onDrag {"))
    #expect(!laneSource.contains("TaskBoardCardPill(label: item.status.title"))
    #expect(laneSource.contains("Text(item.status.title)"))
    #expect(unifiedSource.contains(".dropDestination(for: TaskBoardItemDragPayload.self"))
    #expect(unifiedSource.contains(".dropDestination(for: TaskBoardInboxItemDragPayload.self"))
    #expect(unifiedSource.contains(".onDrop("))
  }

  @Test("Task board lanes keep board column chrome")
  func taskBoardLanesKeepBoardColumnChrome() throws {
    let unifiedSource = try taskBoardSourceFile(named: "TaskBoardLaneUnifiedColumn.swift")
    let laneChromeSource = try taskBoardSourceFile(named: "TaskBoardLaneChrome.swift")
    let overviewSource = try taskBoardSourceFile(named: "TaskBoardOverviewView.swift")

    #expect(unifiedSource.contains(".taskBoardLaneColumnChrome("))
    #expect(laneChromeSource.contains("private struct TaskBoardLaneColumnChrome"))
    #expect(laneChromeSource.contains("private var laneFill: AnyShapeStyle"))
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
    #expect(overviewSupportSource.contains("let height = max(measuredHeight, proposal.height ?? 0)"))
    #expect(laneChromeSource.contains("idealHeight: metrics.laneFixedHeight"))
    #expect(laneChromeSource.contains("minHeight: metrics.laneFixedHeight"))
    #expect(laneChromeSource.contains("maxHeight: .infinity"))
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
      .appendingPathComponent("apps/harness-monitor-macos/Sources/HarnessMonitorUIPreviewable")
      .appendingPathComponent("Views")
      .appendingPathComponent(domain)
      .appendingPathComponent(relativePath)
    return try String(contentsOf: fileURL, encoding: .utf8)
  }
}
