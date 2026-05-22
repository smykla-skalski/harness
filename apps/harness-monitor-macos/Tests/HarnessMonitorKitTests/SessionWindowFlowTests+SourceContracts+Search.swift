import Foundation
import Testing

@testable import HarnessMonitorKit
@testable import HarnessMonitorUIPreviewable

extension SessionWindowFlowTests {
  @Test("Session search dependencies are anchored outside the root window graph")
  func sessionSearchDependenciesAreAnchoredOutsideRootWindowGraph() throws {
    let rootSource = try previewableSourceFile(named: "Views/Sessions/SessionWindowView.swift")
    let anchorSource = try previewableSourceFile(
      named: "Views/Sessions/SessionWindowView+BackgroundAnchors.swift"
    )
    let searchHostSource = try previewableSourceFile(
      named: "Views/Sessions/SessionWindowView+SearchHost.swift"
    )
    let columnsSource = try previewableSourceFile(
      named: "Views/Sessions/SessionWindowView+Columns.swift"
    )
    let presentationSource = try previewableSourceFile(
      named: "Views/Sessions/SessionWindowView+Presentation.swift"
    )
    let detailFocusSource = try previewableSourceFile(
      named: "Views/Sessions/SessionWindowView+DetailFocus.swift"
    )

    #expect(rootSource.contains("ZStack {"))
    #expect(rootSource.contains("bodyContent"))
    #expect(rootSource.contains("sessionSearchHost"))
    #expect(rootSource.contains("if !HarnessMonitorPerfIsolation.disablesSearchHost"))
    #expect(!rootSource.contains(".appSearchHost("))
    #expect(
      rootSource.contains(
        ".background {\n      sessionWindowBackgroundAnchors(currentModifiers: $currentModifiers)\n    }"
      )
    )
    #expect(!rootSource.contains(".modifier(SessionWindowSearchMirror"))
    #expect(!rootSource.contains(".modifier(appSearchIndexUpdater"))
    #expect(anchorSource.contains("SessionWindowSearchMirror(stateCache: stateCache"))
    #expect(anchorSource.contains("appSearchIndexUpdaterAnchor"))
    #expect(anchorSource.contains("SessionWindowModifierKeysMonitor"))
    #expect(searchHostSource.contains("AppSearchHost("))
    #expect(searchHostSource.contains("model: stateCache.appSearchModel"))
    #expect(
      searchHostSource.contains("primaryDomainProvider: { stateCache.selection.routeDomain }")
    )
    #expect(!searchHostSource.contains("primaryDomain: stateCache.selection.routeDomain"))
    #expect(searchHostSource.contains("automation: searchAutomation"))
    #expect(!searchHostSource.contains("harnessSessionRouteFocus"))
    #expect(columnsSource.contains(".environment(\\.appSearchModel, stateCache.appSearchModel)"))
    #expect(!presentationSource.contains("appSearchModel.query"))
    #expect(!detailFocusSource.contains("stateCache.appSearchModel.query"))
    #expect(detailFocusSource.contains("SessionRouteAgentDetailFocus"))
    #expect(detailFocusSource.contains("SessionRouteTaskDetailFocus"))
    #expect(detailFocusSource.contains("@Environment(\\.appSearchModel)"))
  }

  @Test("Session search perf script drives the real searchable binding")
  func sessionSearchPerfScriptUsesSearchFieldAutomation() throws {
    let source = try previewableSourceFile(
      named: "Views/Sessions/SessionWindowView+PerfScenarios.swift"
    )

    #expect(source.contains("stateCache.appSearchAutomation.present(query: \"\")"))
    #expect(source.contains("stateCache.appSearchAutomation.present(query: step.query)"))
    #expect(source.contains("stateCache.appSearchAutomation.dismiss()"))
    #expect(source.contains("stateCache.selectRoute(step.route)"))
    #expect(source.contains("let hasSearchCorpus: Bool"))
    #expect(source.contains("guard trigger.hasSearchCorpus else { return }"))
    #expect(!source.contains("supervisorOpenDecisions.count"))
    #expect(source.contains("try? await Task.sleep(for: .milliseconds(260))"))
    #expect(!source.contains("appSearchModel.runSearch(query: step.query"))
    #expect(!source.contains("appSearchModel.setPresented(true)"))
  }

  @Test("Search command is owned by app commands instead of a hidden session button")
  func searchCommandUsesFocusedDispatcher() throws {
    let commandsSource = try harnessSourceFile(named: "App/HarnessMonitorAppCommands.swift")

    #expect(commandsSource.contains("@FocusedValue(\\.harnessSidebarSearchFocusAction)"))
    #expect(commandsSource.contains("Button(searchCommandTitle)"))
    #expect(commandsSource.contains(".keyboardShortcut(\"f\", modifiers: .command)"))
    #expect(commandsSource.contains("searchFocusAction?.invoke()"))
    #expect(commandsSource.contains(".disabled(searchFocusAction?.isAvailable != true)"))
  }

  @Test("Session sidebar toggle perf script drives split view column visibility")
  func sessionSidebarTogglePerfScriptUsesColumnVisibility() throws {
    let source = try previewableSourceFile(
      named: "Views/Sessions/SessionWindowView+PerfScenarios.swift"
    )
    let layoutSource = try previewableSourceFile(
      named: "Views/Sessions/SessionWindowStandardLayout.swift"
    )

    #expect(source.contains("case \"sidebar-toggle-rich-detail\""))
    #expect(source.contains("guard !trigger.sidebarToggleTargets.isEmpty else { return }"))
    #expect(source.contains("await runSidebarToggleRichDetailScript("))
    #expect(source.contains("stateCache.selectAgent(agentID)"))
    #expect(source.contains("stateCache.selectTask(taskID)"))
    #expect(source.contains("stateCache.selectDecision(decisionID)"))
    #expect(source.contains("driveContentDetailDividerSweep"))
    #expect(source.contains("contentDetailDividerWidth = width"))
    #expect(source.contains("columnVisibility = .detailOnly"))
    #expect(source.contains("columnVisibility = .doubleColumn"))
    #expect(layoutSource.contains("columnVisibility: columnVisibilityBinding"))
    #expect(layoutSource.contains("contentDetailDividerWidth: perfContentDividerWidth"))
  }

  @Test("Agent detail deadline clock stays out of text field form state")
  func agentDetailDeadlineClockStaysOutOfTextFieldFormState() throws {
    let sectionSource = try previewableSourceFile(
      named: "Views/Agents/AgentDetailSendUpdateSection.swift"
    )
    let presentationSource = try previewableSourceFile(
      named: "Views/Agents/AgentDetailSendUpdateSection+Presentation.swift"
    )

    #expect(!sectionSource.contains("@State private var deadlineNow"))
    #expect(sectionSource.contains("@State private var deadlineClock"))
    #expect(
      sectionSource.contains("await deadlineClock.run(store: store, deadline: promptDeadlineDate)")
    )
    #expect(sectionSource.contains("AgentDetailDeadlineSendButton("))
    #expect(presentationSource.contains("final class AgentDetailDeadlineClockState"))
    #expect(presentationSource.contains("struct AgentDetailDeadlineSendButton: View"))
    #expect(presentationSource.contains("struct AgentDetailComposerStatusRow: View"))
    #expect(!presentationSource.contains("@State private var deadlineNow"))
  }

  @Test("Session attention focus count ignores route filters")
  func sessionAttentionFocusCountIgnoresRouteFilters() throws {
    let source = try previewableSourceFile(
      named: "Views/Sessions/SessionWindowView+Inspector.swift"
    )

    #expect(source.contains("pendingDecisionCount: allSessionDecisionsCache.count"))
    #expect(!source.contains("pendingDecisionCount: matchingDecisions.count"))
  }

  @Test("Session window state cache skips redundant observable writes")
  func sessionWindowStateCacheSkipsRedundantObservableWrites() throws {
    let source = try previewableSourceFile(named: "Support/SessionWindowStateCache.swift")
    let sectionSource = try previewableSourceFile(named: "Support/SessionWindowSectionState.swift")

    #expect(source.contains("guard sectionState.decisionID != decisionID else { return }"))
    #expect(source.contains("guard sectionState.agentID != agentID else { return }"))
    #expect(source.contains("guard sectionState.taskID != taskID else { return }"))
    #expect(source.contains("if selectionSource != source"))
    #expect(source.contains("guard agentCreateCatalog != nextCatalog else { return }"))
    #expect(source.contains("guard agentCreateCatalog.isLoading else { return }"))
    #expect(sectionSource.contains("assign(\\.routeSelection, route)"))
    #expect(sectionSource.contains("guard self[keyPath: keyPath] != value else { return }"))
    #expect(sectionSource.contains("guard createDrafts[draft.kind] != draft else { return }"))
  }

  @Test("Session shortcut overlays render only while relevant modifiers are held")
  func sessionShortcutOverlaysRenderOnlyWhileRelevantModifiersAreHeld() throws {
    let toolbarSource = try previewableSourceFile(
      named: "Views/Sessions/SessionWindowToolbar.swift"
    )
    let sidebarSource = try previewableSourceFile(named: "Views/Sessions/SessionSidebar.swift")
    let sectionsSource = try previewableSourceFile(
      named: "Views/Sessions/SessionSidebar+Sections.swift"
    )
    let decisionSource = try previewableSourceFile(
      named: "Views/Sessions/SessionSidebarDecisionSection.swift"
    )

    #expect(toolbarSource.contains("private var shouldRenderShortcutOverlay"))
    #expect(toolbarSource.contains("if let shortcutOverlay, shouldRenderShortcutOverlay"))
    #expect(toolbarSource.contains("shouldRenderShortcutOverlay ? 1 : 0"))
    #expect(sidebarSource.contains("var shouldRenderShortcutOverlays"))
    #expect(sidebarSource.contains("createShortcut.isRevealed(by: currentModifiers)"))
    #expect(sidebarSource.contains("if shouldRenderShortcutOverlays"))
    #expect(sectionsSource.contains("let isEnabled: Bool"))
    #expect(sectionsSource.contains("if isEnabled"))
    #expect(sectionsSource.contains("tracksShortcutFrame: shouldRenderShortcutOverlays"))
    #expect(decisionSource.contains("tracksShortcutFrame: shouldRenderShortcutOverlays"))
  }
}
