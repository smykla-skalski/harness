import Foundation
import Testing

@testable import HarnessMonitorUIPreviewable

@Suite("Session SwiftUI source contracts")
struct SessionSwiftUISourceTests {
  @Test(
    "Task detail avoids nested forms while session decisions reuse the rich shared detail"
  )
  func taskAndDecisionDetailSurfacesStayAlignedWithTheirSharedContainers() throws {
    let taskSource = try sourceFile(at: "Views/Sessions/SessionTaskDetailPane.swift")
    let decisionSource = try sourceFile(at: "Views/Sessions/SessionDecisionDetailPane.swift")
    let codexSource = try sourceFile(at: "Views/Sessions/SessionCodexRunDetailSection.swift")
    let agentDetailSource = try sourceFile(at: "Views/Sessions/SessionAgentDetailSection.swift")
    let agentViewportSource = try sourceFile(at: "Views/Sessions/SessionAgentLaneViews.swift")
    let columnsSource = try sourceFile(at: "Views/Sessions/SessionWindowView+Columns.swift")

    #expect(
      taskSource.contains("SessionDetailScrollSurface(contentPadding: metrics.contentPadding)")
    )
    #expect(taskSource.contains("VStack(alignment: .leading, spacing: metrics.sectionSpacing)"))
    #expect(taskSource.contains("SessionDetailPanel(title: \"Task\")"))
    #expect(taskSource.contains("SessionDetailFactsGrid("))
    #expect(taskSource.contains(".harnessNativeFormControl()"))
    #expect(!taskSource.contains("Form {"))
    #expect(!taskSource.contains(".harnessNativeFormContainer()"))
    #expect(!taskSource.contains(".contentMargins("))
    #expect(!taskSource.contains(".scrollContentBackground(.hidden)"))
    #expect(decisionSource.contains("SessionFilteredDecisionNotice("))
    #expect(decisionSource.contains("DecisionDetailView("))
    #expect(decisionSource.contains("handler: actionHandler"))
    #expect(decisionSource.contains("auditEvents: auditEvents"))
    #expect(!decisionSource.contains("HarnessMonitorJSONCodeBlock("))
    #expect(!decisionSource.contains("Form {"))
    #expect(codexSource.contains("SessionDetailScrollSurface("))
    #expect(!codexSource.contains("ScrollView {"))
    #expect(!agentDetailSource.contains("SessionDetailScrollSurface("))
    #expect(agentViewportSource.contains(".scrollBounceBehavior(.always, axes: .vertical)"))
    #expect(columnsSource.contains("SessionDetailEmptySurface {"))
  }

  @Test("Form sections use shared font scaling helpers")
  func formSectionsUseSharedFontScalingHelpers() throws {
    let themeSource = try sourceFile(at: "Theme/HarnessMonitorTextSize.swift")
    let sectionFiles = [
      "Views/Sessions/SessionWindowCreateForm.swift",
      "Views/Settings/SettingsConnectionCard.swift",
      "Views/Settings/SettingsCodexSection.swift",
      "Views/Settings/SettingsConnectionSection.swift",
      "Views/Settings/SettingsDiagnosticsOverview.swift",
      "Views/Settings/SettingsDiagnosticsSection.swift",
      "Views/Settings/SettingsNotificationsSection.swift",
      "Views/Settings/SettingsPathsSection.swift",
      "Views/Settings/SettingsRecentEventsCard.swift",
      "Views/Settings/SettingsStatusSection.swift",
      "Views/Settings/Supervisor/SettingsSupervisorBackgroundPane.swift",
    ]
    let footerFiles = [
      "Views/Settings/SettingsCodexSection.swift",
      "Views/Settings/SettingsNotificationsSection.swift",
      "Views/Settings/Supervisor/SettingsSupervisorBackgroundPane.swift",
    ]
    let containerFiles = [
      "Views/Sessions/SessionWindowCreateForm.swift"
    ]

    #expect(themeSource.contains("func harnessNativeFormSectionHeader()"))
    #expect(themeSource.contains("func harnessNativeFormSectionFooter()"))
    #expect(themeSource.contains(".scaledFont(.caption.weight(.semibold))"))
    #expect(themeSource.contains(".accessibilityAddTraits(.isHeader)"))
    #expect(themeSource.contains(".scaledFont(.caption)"))

    for relativePath in sectionFiles {
      let source = try sourceFile(at: relativePath)
      #expect(source.contains(".harnessNativeFormSectionHeader()"))
      #expect(!source.contains("Section(\""))
    }

    for relativePath in footerFiles {
      let source = try sourceFile(at: relativePath)
      #expect(source.contains(".harnessNativeFormSectionFooter()"))
    }

    for relativePath in containerFiles {
      let source = try sourceFile(at: relativePath)
      #expect(source.contains(".harnessNativeFormContainer()"))
    }

    let createFormSource = try sourceFile(at: "Views/Sessions/SessionWindowCreateForm.swift")
    #expect(!createFormSource.contains("Section(draft.kind.title)"))
    #expect(createFormSource.contains("embeddedAgentRuntimeSections"))
    #expect(createFormSource.contains("Picker(\"Provider\", selection: selectedProviderID)"))
    #expect(
      createFormSource.contains(
        ".contentMargins(.horizontal, metrics.formPadding, for: .scrollContent)"
      )
    )
    #expect(
      createFormSource.contains(
        ".contentMargins(.vertical, metrics.formPadding, for: .scrollContent)"
      )
    )
    #expect(createFormSource.contains(".scrollContentBackground(.hidden)"))
    #expect(!createFormSource.contains(".padding(metrics.formPadding)"))
    #expect(!createFormSource.contains("DisclosureGroup(\""))
    #expect(!createFormSource.contains("SessionWindowCreateFieldBlock("))
  }

  @Test("Session view state wrappers stay private")
  func sessionViewStateWrappersStayPrivate() throws {
    let sessionWindowSource = try sourceFile(at: "Views/Sessions/SessionWindowView.swift")
    let createFormSource = try sourceFile(at: "Views/Sessions/SessionWindowCreateForm.swift")

    #expect(sessionWindowSource.contains("@State private var decisionCacheStorage"))
    #expect(!sessionWindowSource.contains("@State var allSessionDecisionsCache"))
    #expect(!sessionWindowSource.contains("@State var matchingDecisionsCache"))
    #expect(!sessionWindowSource.contains("@State var detailRenderedSelection"))
    #expect(!sessionWindowSource.contains("@State var contentRenderedRoute"))
    #expect(sessionWindowSource.contains("private var focusModeStorage = false"))
    #expect(sessionWindowSource.contains("private var inspectorVisibleStorage = false"))
    #expect(sessionWindowSource.contains("private var inspectorPreferredStorage = false"))
    #expect(sessionWindowSource.contains("private var inspectorWidthStorage = 280.0"))
    #expect(sessionWindowSource.contains("private var sidebarWidthStorage = 200.0"))
    #expect(sessionWindowSource.contains("@State private var liveInspectorWidthStorage: Double?"))
    #expect(
      sessionWindowSource.contains("@State private var liveContentColumnWidthStorage: Double?")
    )
    #expect(
      sessionWindowSource.contains(
        "private var contentColumnWidthStorage = SessionContentDetailSplitLayout.defaultContentWidth"
      )
    )
    #expect(sessionWindowSource.contains("private var columnVisibilityRawStorage = \"automatic\""))
    #expect(
      !sessionWindowSource.contains(
        "@SceneStorage(\"session.focusMode\")\n  var focusMode = false"
      )
    )
    #expect(
      !sessionWindowSource.contains(
        "@SceneStorage(\"session.inspector.visible\")\n  var inspectorVisible = false"
      )
    )
    #expect(
      !sessionWindowSource.contains(
        "@SceneStorage(\"session.inspector.preferred\")\n  var inspectorPreferred = false"
      )
    )

    #expect(createFormSource.contains("@State private var stateStorage"))
    #expect(createFormSource.contains("@FocusState private var focusedFieldStorage"))
    #expect(!createFormSource.contains("@State var validationResult"))
    #expect(!createFormSource.contains("@State var agentCapabilityOptions"))
    #expect(!createFormSource.contains("@FocusState var focusedField"))
  }

  @Test("Session content columns extend behind toolbar glass with soft scroll edge")
  func sessionContentColumnsExtendBehindToolbarGlassWithSoftScrollEdge() throws {
    let columnsSource = try sourceFile(at: "Views/Sessions/SessionWindowView+Columns.swift")
    let extensionEffectSource = try sourceFile(
      at: "Views/Sessions/SessionWindowBackgroundExtensionEffect.swift"
    )
    let surfaceSource = try sourceFile(at: "Views/Sessions/SessionDetailSurface.swift")

    #expect(!columnsSource.contains("SessionBackgroundExtensionSurface()"))
    #expect(
      columnsSource.components(separatedBy: ".sessionWindowBackgroundExtensionEffect()").count
        - 1 == 2
    )
    #expect(
      extensionEffectSource.contains("@AppStorage(HarnessMonitorBackdropDefaults.modeKey)")
    )
    #expect(extensionEffectSource.contains("@Environment(\\.accessibilityReduceTransparency)"))
    #expect(extensionEffectSource.contains("if reduceTransparency || backdropMode == .none"))
    #expect(extensionEffectSource.contains("func harnessMonitorBackgroundExtensionEffect()"))
    #expect(extensionEffectSource.contains("content.backgroundExtensionEffect()"))
    #expect(!surfaceSource.contains(".backgroundExtensionEffect()"))
    #expect(surfaceSource.contains("topScrollEdgeEffect: .soft"))
  }

  @Test("Session split view and search bindings ignore redundant writes")
  func sessionSplitViewAndSearchBindingsIgnoreRedundantWrites() throws {
    let sessionWindowSource = try sourceFile(at: "Views/Sessions/SessionWindowView.swift")
    let widthPersistenceSource = try sourceFile(
      at: "Views/Sessions/SessionWindowView+WidthPersistence.swift"
    )
    let presentationSource = try sourceFile(
      at: "Views/Sessions/SessionWindowView+Presentation.swift")
    let sidebarSearchSource = try sourceFile(at: "Views/Sidebar/SidebarSearchHost.swift")

    #expect(presentationSource.contains("let encodedVisibility ="))
    #expect(presentationSource.contains("guard columnVisibilityRaw != encodedVisibility else"))
    #expect(sessionWindowSource.contains("if focusModeStorage != $0"))
    #expect(sessionWindowSource.contains("if inspectorVisibleStorage != $0"))
    #expect(sessionWindowSource.contains("if inspectorPreferredStorage != $0"))
    #expect(widthPersistenceSource.contains("guard abs(inspectorWidth - newValue) > 0.5 else"))
    #expect(
      widthPersistenceSource.contains("guard abs(contentColumnWidth - newValue) > 0.5 else")
    )
    #expect(sidebarSearchSource.contains("guard store.searchText != newValue else { return }"))
    #expect(
      sidebarSearchSource.contains(
        "guard searchPresentationState.isPresented != newValue else { return }"
      )
    )
    #expect(!sidebarSearchSource.contains("private var mcpRegistryHostEnabled"))
  }

  @Test("App search reindex tasks attach only while search is visible")
  func appSearchReindexTasksAttachOnlyWhileSearchIsVisible() throws {
    let searchUpdaterSource = try sourceFile(at: "Views/Search/AppSearchIndexUpdater.swift")

    #expect(searchUpdaterSource.contains("@ViewBuilder\n  func body(content: Content)"))
    #expect(searchUpdaterSource.contains("if model.isPresented {"))
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
    #expect(
      supportSource.contains("if HarnessMonitorUITestEnvironment.generalMarkersEnabled")
    )
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
    let navigationSource = try sourceFile(
      at: "Views/Timeline/SessionTimelineNavigationControls.swift")

    #expect(timelineSource.contains("ScrollView(.vertical)"))
    #expect(timelineSource.contains("LazyVStack"))
    #expect(!timelineSource.contains("SessionTimelineTableView"))
    #expect(!timelineSource.contains("SessionTimelineViewportModel"))
    #expect(!timelineSource.contains("NSScrollView"))
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
