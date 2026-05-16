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
    let detailFocusSource = try sourceFile(at: "Views/Sessions/SessionWindowView+DetailFocus.swift")

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
    #expect(
      decisionSource.contains(
        "auditEventPayloadPresentations: auditEventPayloadPresentations"
      )
    )
    #expect(!decisionSource.contains("HarnessMonitorJSONCodeBlock("))
    #expect(!decisionSource.contains("Form {"))
    #expect(codexSource.contains("SessionDetailScrollSurface("))
    #expect(!codexSource.contains("ScrollView {"))
    #expect(!agentDetailSource.contains("SessionDetailScrollSurface("))
    #expect(agentViewportSource.contains(".scrollBounceBehavior(.always, axes: .vertical)"))
    #expect(columnsSource.contains("SessionDetailEmptySurface {"))
    #expect(
      detailFocusSource.contains(
        "auditEventPayloadPresentations: stateCache.decisionRuntime.auditEventPayloadPresentations"
      )
    )
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

  @Test("Settings string pickers and capability lists keep duplicate values off self identity")
  func settingsStringCollectionsAvoidSelfIdentity() throws {
    let codexSource = try sourceFile(at: "Views/Settings/SettingsCodexSection.swift")
    let parameterRowSource = try sourceFile(
      at: "Views/Settings/Supervisor/SettingsSupervisorRulesPane+ParameterRow.swift"
    )

    #expect(codexSource.contains("ForEach(Array(capabilityNames.enumerated()), id: \\.offset)"))
    #expect(!codexSource.contains("ForEach(capabilityNames, id: \\.self)"))
    #expect(
      parameterRowSource.contains("ForEach(Array(allowedValues.enumerated()), id: \\.offset)")
    )
    #expect(!parameterRowSource.contains("ForEach(allowedValues, id: \\.self)"))
  }

  @Test("Session runtime strings and composer rows avoid self identity")
  func sessionRuntimeStringsAndComposerRowsAvoidSelfIdentity() throws {
    let runtimeRowsSource = try sourceFile(
      at: "Views/Sessions/SessionWindowCreateForm+RuntimeRows.swift")
    let composerSource = try sourceFile(at: "Views/Sessions/SessionAgentComposer.swift")

    #expect(runtimeRowsSource.contains("ForEach(Array(values.enumerated()), id: \\.offset)"))
    #expect(!runtimeRowsSource.contains("ForEach(values, id: \\.self)"))
    #expect(
      composerSource.contains(
        "ForEach(Array(SessionAgentComposerKeyLayout.rows.enumerated()), id: \\.offset)")
    )
    #expect(!composerSource.contains("ForEach(SessionAgentComposerKeyLayout.rows, id: \\.self)"))
  }

  @Test("Session view state wrappers stay private")
  func sessionViewStateWrappersStayPrivate() throws {
    let sessionWindowSource = try sourceFile(at: "Views/Sessions/SessionWindowView.swift")
    let standardLayoutSource = try sourceFile(
      at: "Views/Sessions/SessionWindowStandardLayout.swift")
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
    #expect(!sessionWindowSource.contains("private var columnVisibilityRawStorage"))
    #expect(standardLayoutSource.contains("private var columnVisibilityRawStorage = \"automatic\""))
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

  @Test("Dashboard detail surface reuses the shared toolbar blur host")
  func dashboardDetailSurfaceReusesSharedToolbarBlurHost() throws {
    let dashboardSource = try sourceFile(at: "Views/Dashboard/DashboardWindowView.swift")

    #expect(dashboardSource.contains(".harnessMonitorBackgroundExtensionEffect()"))
    #expect(!dashboardSource.contains(".toolbarBackground(.visible, for: .windowToolbar)"))
    #expect(!dashboardSource.contains(".backgroundExtensionEffect()"))
  }

  @Test("Session split view and search bindings ignore redundant writes")
  func sessionSplitViewAndSearchBindingsIgnoreRedundantWrites() throws {
    let sessionWindowSource = try sourceFile(at: "Views/Sessions/SessionWindowView.swift")
    let widthPersistenceSource = try sourceFile(
      at: "Views/Sessions/SessionWindowView+WidthPersistence.swift"
    )
    let presentationSource = try sourceFile(
      at: "Views/Sessions/SessionWindowView+Presentation.swift")
    let standardLayoutSource = try sourceFile(
      at: "Views/Sessions/SessionWindowStandardLayout.swift")
    let sidebarSearchSource = try sourceFile(at: "Views/Sidebar/SidebarSearchHost.swift")

    #expect(!presentationSource.contains("let encodedVisibility ="))
    #expect(standardLayoutSource.contains("let encodedVisibility ="))
    #expect(standardLayoutSource.contains("guard columnVisibilityRaw != encodedVisibility else"))
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
    #expect(sidebarSearchSource.contains("SidebarSearchableModifier("))
    #expect(sidebarSearchSource.contains(".task(id: canPresentSearch)"))
    #expect(
      sidebarSearchSource.contains(
        "requestPresentation(canPresent: canPresentSearch)"
      )
    )
    #expect(!sidebarSearchSource.contains("private var mcpRegistryHostEnabled"))
  }

  @Test("Decision rows keep deadline churn scoped to the deadline chip")
  func decisionRowsKeepTimelineTicksOutOfTheRowBody() throws {
    let rowSource = try sourceFile(at: "Views/Decisions/DecisionRow.swift")

    #expect(!rowSource.contains("TimelineView("))
    #expect(rowSource.contains("let showsDeadline = acpPayload?.expiresAtDate != nil"))
    #expect(rowSource.contains("referenceDate: nil"))
    #expect(!rowSource.contains("deadlineStatus("))
  }

  @Test("Decision live tick keeps duplicate quarantined rules off self identity")
  func decisionLiveTickKeepsDuplicateRuleIDsOffSelfIdentity() throws {
    let source = try sourceFile(at: "Views/Decisions/DecisionsLiveTickView.swift")

    #expect(source.contains("private var indexedRuleIDs"))
    #expect(source.contains("ForEach(indexedRuleIDs, id: \\.offset)"))
    #expect(!source.contains("ForEach(ruleIDs, id: \\.self)"))
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
