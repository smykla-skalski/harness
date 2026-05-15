import Foundation
import Testing

@testable import HarnessMonitorUIPreviewable

@Suite("Session SwiftUI operational source contracts")
struct SessionSwiftUIOperationalSourceTests {
  @Test("Timeline rows reuse shared formatter helpers instead of allocating local formatter banks")
  func timelineRowsReuseSharedFormatterHelpers() throws {
    let source = try sourceFile(at: "Views/Timeline/SessionTimelineDayDivider.swift")

    #expect(source.contains("timelineDayStart(for: node.timestamp, configuration: configuration)"))
    #expect(
      source.contains("formatTimelineDayDivider(node.timestamp, configuration: configuration)")
    )
    #expect(source.contains("formatTimelineTime(node.timestamp, configuration: configuration)"))
    #expect(
      source.contains("formatTimelineTimestamp(node.timestamp, configuration: configuration)")
    )
    #expect(source.contains("private static func resolvedTimeLabel"))
    #expect(source.contains("private static func resolvedTimestampLabel"))
    #expect(source.contains("private static func resolvedAccessibilityLabel"))
    #expect(!source.contains("private final class SessionTimelineRowFormatter"))
    #expect(!source.contains("DateFormatter()"))
  }

  @Test("App search reindex tasks attach from a tiny active-search anchor")
  func appSearchReindexTasksAttachFromTinyActiveSearchAnchor() throws {
    let searchUpdaterSource = try sourceFile(at: "Views/Search/AppSearchIndexUpdater.swift")

    #expect(searchUpdaterSource.contains("struct AppSearchIndexUpdater: View"))
    #expect(searchUpdaterSource.contains("@ViewBuilder var body: some View"))
    #expect(searchUpdaterSource.contains("if model.isPresented {"))
    #expect(searchUpdaterSource.contains("Color.clear"))
    #expect(searchUpdaterSource.contains(".frame(width: 0, height: 0)"))
    #expect(searchUpdaterSource.contains(".task(id: agentSignature)"))
    #expect(searchUpdaterSource.contains(".task(id: decisionSignature)"))
    #expect(searchUpdaterSource.contains(".task(id: taskSignature)"))
    #expect(searchUpdaterSource.contains(".task(id: eventSignature)"))
    #expect(!searchUpdaterSource.contains("AppSearchReindexTrigger(active:"))
    #expect(!searchUpdaterSource.contains("guard model.isPresented else { return }"))
  }

  @Test("Refresh toolbar keeps idle arrow on a static symbol path")
  func refreshToolbarKeepsIdleArrowOnStaticSymbolPath() throws {
    let toolbarSource = try sourceFile(at: "Views/App/ContentChromeToolbarSupport.swift")

    #expect(toolbarSource.contains("if model.manualRefreshSuccessToken > 0 {"))
    #expect(toolbarSource.contains(".task(id: model.manualRefreshSuccessToken)"))
    #expect(toolbarSource.contains("private var usesAnimatedSymbolEffects: Bool"))
    #expect(toolbarSource.contains("if usesAnimatedSymbolEffects {"))
    #expect(toolbarSource.contains("private var simpleToolbarSymbol: some View"))
    #expect(toolbarSource.contains("private var animatedToolbarSymbol: some View"))
    #expect(!toolbarSource.contains("shouldSpin"))
    #expect(!toolbarSource.contains(".symbolEffect(.rotate"))
  }

  @Test("Session sidebar keeps static routes visible while deferred rows load")
  func sessionSidebarKeepsStaticRoutesVisibleWhileDeferredRowsLoad() throws {
    let sidebarSource = try sourceFile(at: "Views/Sessions/SessionSidebar.swift")

    #expect(sidebarSource.contains("@State private var showsDeferredSidebarSections = false"))
    #expect(sidebarSource.contains("List(selection: nativeSelectionBinding) {"))
    #expect(sidebarSource.contains("sidebarRouteSection"))
    #expect(sidebarSource.contains("if showsDeferredSidebarSections {"))
    #expect(sidebarSource.contains("private var sidebarRouteSection: some View"))
    #expect(sidebarSource.contains("private var pendingRouteSection: some View"))
    #expect(sidebarSource.contains("selectPendingRoute(route)"))
    #expect(sidebarSource.contains("ProgressView()"))
    #expect(sidebarSource.contains("\"Loading session items\""))
    #expect(sidebarSource.contains("sessionWindowSidebarDeferredLoader"))
    #expect(sidebarSource.contains("Agents, decisions, and tasks will appear shortly."))
    #expect(!sidebarSource.contains("private var pendingSidebarList: some View"))
  }

  @Test("Disabled visual perf variants reuse base routes and skip optional session chrome")
  func disabledVisualPerfVariantsReuseBaseRoutesAndSkipOptionalSessionChrome() throws {
    #expect(
      HarnessMonitorUITestEnvironment.basePerfScenario(
        for: "timeline-filter-form-visual-options-disabled"
      ) == "timeline-filter-form"
    )
    #expect(
      HarnessMonitorUITestEnvironment.basePerfScenario(for: "session-search-full")
        == "session-search-full"
    )
    #expect(
      HarnessMonitorUITestEnvironment.basePerfScenario(
        for: "sidebar-toggle-rich-detail-visual-options-disabled"
      ) == "sidebar-toggle-rich-detail"
    )
    #expect(
      HarnessMonitorUITestEnvironment.disablesVisualOptions(
        for: "open-session-window-visual-options-disabled"
      )
    )
    #expect(!HarnessMonitorUITestEnvironment.disablesVisualOptions(for: "open-session-window"))
    #expect(!HarnessMonitorUITestEnvironment.disablesVisualOptions(for: nil))

    let supportSource = try sourceFile(at: "Support/HarnessMonitorAccessibilitySupport.swift")
    let titleBlurSource = try sourceFile(at: "Views/Sessions/SessionTitleBlurChrome.swift")
    let toolbarSource = try sourceFile(at: "Views/Sessions/SessionWindowToolbar.swift")
    let sidebarSource = try sourceFile(at: "Views/Sessions/SessionSidebar.swift")
    let timelineSupportSource = try sourceFile(
      at: "Views/Timeline/MonitorTimelineSection+Support.swift"
    )

    #expect(supportSource.contains("visualOptionsDisabledSuffix"))
    #expect(supportSource.contains("perfScenarioBaseValue"))
    #expect(supportSource.contains("generalMarkersEnabled"))
    #expect(supportSource.contains("if HarnessMonitorUITestEnvironment.generalMarkersEnabled"))
    #expect(titleBlurSource.contains("private var shouldShowTitleBlur"))
    #expect(titleBlurSource.contains("!HarnessMonitorUITestEnvironment.disablesVisualOptions"))
    #expect(toolbarSource.contains("private var shouldShowShortcutOverlays"))
    #expect(toolbarSource.contains("!HarnessMonitorUITestEnvironment.disablesVisualOptions"))
    #expect(sidebarSource.contains("private var shouldShowShortcutOverlays"))
    #expect(sidebarSource.contains("!HarnessMonitorUITestEnvironment.disablesVisualOptions"))
    #expect(timelineSupportSource.contains("perfScenarioBaseValue == \"timeline-filter-form\""))
    #expect(!timelineSupportSource.contains("perfScenarioRawValue == \"timeline-filter-form\""))
  }

  @Test("Timeline section renders on SwiftUI primitives without AppKit scroll machinery")
  func timelineSectionRendersOnSwiftUIPrimitives() throws {
    let timelineSource = try sourceFile(at: "Views/Timeline/MonitorTimelineSection.swift")
    let timelineListSource = try sourceFile(at: "Views/Timeline/SessionTimelineList.swift")
    let navigationSource = try sourceFile(
      at: "Views/Timeline/SessionTimelineNavigationControls.swift")

    #expect(timelineListSource.contains("ScrollView(.vertical)"))
    #expect(timelineListSource.contains("LazyVStack"))
    #expect(!timelineSource.contains("SessionTimelineTableView"))
    #expect(!timelineSource.contains("SessionTimelineViewportModel"))
    #expect(!timelineSource.contains("NSScrollView"))
    #expect(!timelineListSource.contains("SessionTimelineTableView"))
    #expect(!timelineListSource.contains("SessionTimelineViewportModel"))
    #expect(!timelineListSource.contains("NSScrollView"))
    #expect(navigationSource.contains("struct SessionTimelineCountSummary"))
    #expect(!navigationSource.contains("SessionTimelineNavigationButtonRow"))
    #expect(!navigationSource.contains("SessionTimelineNavigationVisibilityStatus"))
  }

  @Test("Session agent detail reuses the rich agent detail bands with session-scoped inputs")
  func sessionAgentDetailReusesRichBandsWithSessionScopedInputs() throws {
    let detailFocusSource = try sourceFile(at: "Views/Sessions/SessionWindowView+DetailFocus.swift")
    let agentDetailSource = try sourceFile(at: "Views/Sessions/SessionAgentDetailSection.swift")
    let agentDetailComputedSource = try sourceFile(
      at: "Views/Sessions/SessionAgentDetailSection+Computed.swift")
    let expectedAgentTimeline =
      "let agentTimeline = snapshot.timelineEntriesByAgentID[agentID] ?? []"

    #expect(detailFocusSource.contains("detail: detail"))
    #expect(detailFocusSource.contains(expectedAgentTimeline))
    #expect(detailFocusSource.contains("agentTimeline: agentTimeline"))
    #expect(agentDetailSource.contains("let detail: SessionDetail"))
    #expect(agentDetailSource.contains("let agentTimeline: [TimelineEntry]"))
    #expect(agentDetailComputedSource.contains("store.acpRuntimeState("))
    #expect(agentDetailComputedSource.contains("sessionRegistrations: detail.agents"))
    #expect(agentDetailSource.contains("AgentDetailSummaryBand("))
    #expect(agentDetailSource.contains("AgentDetailActivityBand("))
    #expect(agentDetailSource.contains("AgentDetailActionBand("))
    #expect(agentDetailComputedSource.contains("agent.managedAgent?.kind == .tui"))
  }

  @Test("Toast keeps its AppKit pointer shield while spinner stays pure SwiftUI")
  func toastKeepsPointerShieldWhileSpinnerAvoidsInterop() throws {
    let toastSource = try sourceFile(at: "Views/Attention/AcpPermissionAttentionToastView.swift")
    let spinnerSource = try sourceFile(at: "Views/Shared/HarnessMonitorSpinner.swift")

    #expect(toastSource.contains("@Entry public var acpToastOpenDecisions"))
    #expect(toastSource.contains("@Entry public var acpToastDismiss"))
    #expect(!toastSource.contains("EnvironmentKey"))
    #expect(toastSource.contains("NSViewRepresentable"))
    #expect(toastSource.contains("override func mouseDown"))
    #expect(toastSource.contains("override func rightMouseDown"))
    #expect(toastSource.contains("override func otherMouseDown"))
    #expect(!spinnerSource.contains("NSViewRepresentable"))
  }

  private func sourceFile(at relativePath: String) throws -> String {
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
      .appendingPathComponent(relativePath)
    return try String(contentsOf: fileURL, encoding: .utf8)
  }
}
