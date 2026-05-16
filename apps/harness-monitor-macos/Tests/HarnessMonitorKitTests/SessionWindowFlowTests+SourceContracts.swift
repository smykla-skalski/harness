import Foundation
import Testing

@testable import HarnessMonitorKit
@testable import HarnessMonitorUIPreviewable

extension SessionWindowFlowTests {
  @Test("Open Recent window does not show the close-after-pick checkbox")
  func openRecentDoesNotRenderCloseAfterPickCheckbox() throws {
    let source = try previewableSourceFile(named: "Views/Sessions/OpenRecentView.swift")

    #expect(
      !source.contains(
        "Toggle(\"Close Open Recent after picking a session\", isOn: $closeAfterPick)"))
    #expect(!source.contains(".onGeometryChange("))
    #expect(source.contains("OpenRecentStartPanelLayout("))
    #expect(!source.contains("SessionBackgroundExtensionSurface()"))
    #expect(source.contains(".harnessMonitorBackgroundExtensionEffect()"))
    #expect(!source.contains(".backgroundExtensionEffect()"))
    #expect(source.contains("store.sessionIndex.catalog.recentSessions.prefix(8).map"))
    #expect(!source.contains("OpenRecentProjectGroup"))
    #expect(source.contains("OpenRecentSessionStatusDot(status:"))
    #expect(!source.contains("sessionStatusSymbol("))
  }

  @MainActor
  @Test("Open Recent motion policy disables animation for reduce motion")
  func openRecentCloseAfterPickMotionPolicyRespectsReduceMotion() {
    #expect(OpenRecentCloseAfterPickMotionPolicy.animation(reduceMotion: true) == nil)
    #expect(OpenRecentCloseAfterPickMotionPolicy.animation(reduceMotion: false) != nil)
    #expect(OpenRecentCloseAfterPickMotionPolicy.dismissDelay(reduceMotion: true) == .zero)
    #expect(
      OpenRecentCloseAfterPickMotionPolicy.dismissDelay(reduceMotion: false)
        == .milliseconds(160)
    )
  }

  @Test("Open Recent close-after-pick uses native SwiftUI scene routing")
  func openRecentCloseAfterPickUsesCurrentWindowDismiss() throws {
    let source = try previewableSourceFile(named: "Views/Sessions/OpenRecentView.swift")

    #expect(!source.contains("import AppKit"))
    #expect(source.contains("@Environment(\\.dismiss)"))
    #expect(source.contains("@Environment(\\.openWindow)"))
    #expect(source.contains("openWindow.openHarnessSessionWindow"))
    #expect(source.contains("await Task.yield()"))
    #expect(source.contains("dismiss()"))
    #expect(!source.contains("OpenRecentSessionLaunchHandoff"))
    #expect(!source.contains("OpenRecentSourceWindowResolver"))
    #expect(!source.contains("NSApplication"))
    #expect(!source.contains("NSWindow"))
    #expect(!source.contains("requestUserAttention"))
    #expect(!source.contains("makeKeyAndOrderFront"))
    #expect(!source.contains("sourceWindow.close()"))
    #expect(!source.contains("@Environment(\\.dismissWindow)"))
    #expect(!source.contains("dismissWindow(id: HarnessMonitorWindowID.openRecent)"))
    #expect(!source.contains("openWindow(id: HarnessMonitorWindowID.openRecent)"))
  }

  @Test("Session tabs route through SwiftUI commands plus the tabbing accessor")
  func sessionTabsUseSwiftUISceneCommands() throws {
    let appSource = try harnessSourceFile(named: "App/HarnessMonitorApp.swift")
    let scenesSource = try harnessSourceFile(named: "App/HarnessMonitorApp+Scenes.swift")
    let sceneContentSource = try harnessSourceFile(
      named: "App/HarnessMonitorApp+SceneContent.swift")
    let routerSource = try harnessSourceFile(named: "App/HarnessMonitorInitialWindowRouter.swift")
    let rootSource = try harnessSourceFile(named: "App/SessionWindowRootView.swift")
    let commandsSource = try harnessSourceFile(named: "Commands/WindowMenuCommands.swift")
    let tabbingAccessorPath = harnessSourceURL(named: "App/SessionWindowTabbing.swift").path
    let tabbingSource = try harnessSourceFile(named: "App/SessionWindowTabbing.swift")
    let tabbingSupportSource = try previewableSourceFile(
      named: "Support/SessionWindowTabbingSupport.swift"
    )

    #expect(FileManager.default.fileExists(atPath: tabbingAccessorPath))
    #expect(appSource.contains("dashboardWindowScene"))
    #expect(appSource.contains("sessionWindowScene"))
    #expect(scenesSource.contains("Window("))
    #expect(scenesSource.contains("WindowGroup("))
    #expect(scenesSource.contains("id: HarnessMonitorWindowID.dashboard"))
    #expect(scenesSource.contains("id: HarnessMonitorWindowID.sessionScene"))
    #expect(scenesSource.contains("for: SessionWindowToken.self"))
    #expect(
      scenesSource.contains(
        ".restorationBehavior(allowsWindowRestoration ? .automatic : .disabled)"
      )
    )
    #expect(scenesSource.contains(".commandsRemoved()"))
    #expect(sceneContentSource.contains("SessionWindowTabbing(role: .dashboard)"))
    #expect(commandsSource.contains("@Environment(\\.openWindow)"))
    #expect(commandsSource.contains("openHarnessSessionWindow"))
    #expect(rootSource.contains("SessionWindowTabbing("))
    #expect(rootSource.contains("role: .session"))
    #expect(rootSource.contains("private var hostsSharedShellPresentation"))
    #expect(rootSource.contains("HarnessMonitorConfirmationDialogModifier("))
    #expect(rootSource.contains("HarnessMonitorSheetModifier("))
    #expect(rootSource.contains("isEnabled: hostsSharedShellPresentation"))
    #expect(rootSource.contains("CGSize(width: 920, height: 620)"))
    #expect(
      rootSource.contains(
        "HarnessMonitorAccessibility.sessionWindowToolbarSeparatorSuppressed"
      )
    )
    #expect(tabbingSource.contains("scheduleWindowTabbingApplication()"))
    #expect(tabbingSource.contains("await Task.yield()"))
    #expect(tabbingSource.contains("guard window.toolbar != nil else"))
    #expect(tabbingSource.contains("titlebarSeparatorStyle"))
    #expect(routerSource.contains("SessionWindowTabGroupReplayer.replay("))
    #expect(routerSource.contains("let tabReadyWindows = grouping.sessionIDs.compactMap"))
    #expect(routerSource.contains("isWindowTabReady"))
    #expect(routerSource.contains("tab_ready_members="))
    #expect(routerSource.contains("groups_resolved="))
    #expect(tabbingSupportSource.contains("tabbingIdentifier"))
    #expect(tabbingSupportSource.contains("shouldPreferTabbedOpen"))
    #expect(tabbingSupportSource.contains("visibleTabTargetWindow"))
  }

  @Test("Dashboard window routing reuses the shared tab helper")
  func dashboardWindowRoutingUsesSharedTabHelper() throws {
    let routingSource = try harnessSourceFile(
      named: "App/HarnessMonitorApp+InitialWindowRouting.swift")
    let menuBarSource = try harnessSourceFile(named: "App/HarnessMonitorMenuBarExtra.swift")
    let windowCommandsSource = try harnessSourceFile(named: "Commands/WindowMenuCommands.swift")
    let recentCommandsSource = try harnessSourceFile(named: "Commands/RecentSessionsCommand.swift")
    let openActionSource = try previewableSourceFile(named: "Support/SessionWindowOpenAction.swift")
    let unavailableSource = try previewableSourceFile(
      named: "Views/Sessions/SessionWindowView+Unavailable.swift"
    )

    #expect(openActionSource.contains("public func openHarnessDashboardWindow()"))
    #expect(
      openActionSource.contains(
        "guard let sessionID, !sessionID.isEmpty else {\n      openHarnessDashboardWindow()"))
    #expect(openActionSource.contains("mergeNewestTabbedWindowIfNeeded"))
    #expect(windowCommandsSource.contains("openWindow.openHarnessDashboardWindow()"))
    #expect(recentCommandsSource.contains("openWindow.openHarnessDashboardWindow()"))
    #expect(routingSource.contains("openWindow.openHarnessDashboardWindow()"))
    #expect(menuBarSource.contains("openWindow.openHarnessDashboardWindow()"))
    #expect(unavailableSource.contains("openWindow.openHarnessDashboardWindow()"))
  }

  @Test("Dashboard window open-at-quit state is mirrored end-to-end")
  func dashboardWindowOpenAtQuitStateIsMirroredEndToEnd() throws {
    let sceneContentSource = try harnessSourceFile(
      named: "App/HarnessMonitorApp+SceneContent.swift")
    let modifierSource = try harnessSourceFile(named: "App/DashboardWindowLifecycleModifier.swift")
    let trackerSource = try harnessSourceFile(named: "App/DashboardWindowLifecycleTracker.swift")
    let delegateSource = try harnessSourceFile(named: "App/HarnessMonitorAppDelegate.swift")
    let routerSource = try harnessSourceFile(named: "App/HarnessMonitorInitialWindowRouter.swift")

    #expect(sceneContentSource.contains(".modifier(DashboardWindowLifecycleModifier())"))
    #expect(modifierSource.contains("DashboardWindowLifecycleTracker.shared.markOpen()"))
    #expect(modifierSource.contains("DashboardWindowLifecycleTracker.shared.markClosed()"))
    #expect(trackerSource.contains("static let openAtQuitKey"))
    #expect(trackerSource.contains("func flushOpenAtQuit()"))
    #expect(trackerSource.contains("static func wasOpenAtQuit("))
    #expect(
      delegateSource.contains(
        "DashboardWindowLifecycleTracker.shared.flushOpenAtQuit()"
      )
    )
    #expect(routerSource.contains("DashboardWindowLifecycleTracker.wasOpenAtQuit()"))
  }

  @Test("Decision routing reuses an already open session window")
  func decisionRoutingReusesAnAlreadyOpenSessionWindow() throws {
    let source = try previewableSourceFile(named: "Support/SessionWindowOpenAction.swift")

    #expect(source.contains("store.openSessionWindowIDsSnapshot.contains(sessionID)"))
    #expect(source.contains("NSApplication.shared.activate()"))
    #expect(source.contains("openHarnessSessionWindow(sessionID: sessionID)"))
  }

  @Test("Session inspector divider remains SwiftUI native")
  func sessionInspectorDividerRemainsSwiftUINative() throws {
    let viewSource = try previewableSourceFile(named: "Views/Sessions/SessionWindowView.swift")
    let dividerSource = try previewableSourceFile(
      named: "Views/Sessions/SessionInspectorDivider.swift")

    #expect(!viewSource.contains("import AppKit"))
    #expect(!dividerSource.contains("import AppKit"))
    #expect(dividerSource.contains("DragGesture("))
    #expect(!dividerSource.contains("NSCursor"))
  }

  @Test("Session window owns the content-detail split UX")
  func sessionWindowOwnsTheContentDetailSplitUX() throws {
    let viewSource = try previewableSourceFile(named: "Views/Sessions/SessionWindowView.swift")
    let columnsSource = try previewableSourceFile(
      named: "Views/Sessions/SessionWindowView+Columns.swift"
    )
    let layoutSource = try previewableSourceFile(
      named: "Views/Sessions/SessionWindowStandardLayout.swift"
    )
    let splitSource = try previewableSourceFile(
      named: "Views/Sessions/SessionContentDetailSplitView.swift"
    )

    #expect(viewSource.contains("@SceneStorage(\"session.content-detail.width\")"))
    #expect(viewSource.contains("sessionSurface"))
    #expect(
      columnsSource.contains(
        """
        SessionContentDetailSplitView(
                  contentWidth: contentColumnWidthBinding,
                  perfOverrideContentWidth: perfContentDividerWidthBinding,
                  commitContentWidth: commitContentColumnWidth
        """
      )
    )
    #expect(layoutSource.contains(".navigationSplitViewStyle(.prominentDetail)"))
    #expect(splitSource.contains("NSCursor.resizeLeftRight"))
    #expect(splitSource.contains("@State private var liveContentWidth"))
    #expect(
      splitSource.contains("_liveContentWidth = State(wrappedValue: contentWidth.wrappedValue)"))
    #expect(splitSource.contains(".accessibilityAdjustableAction"))
    #expect(!splitSource.contains(".focusEffectDisabled()"))
    #expect(splitSource.contains(".focusable(interactions: .activate)"))
    #expect(splitSource.contains("if !isDragging {"))
    #expect(splitSource.contains(".onMoveCommand"))
  }

  @Test("Session decisions split data refresh from filter-only churn")
  func sessionDecisionsSplitDataRefreshFromFilterOnlyChurn() throws {
    let policySource = try previewableSourceFile(
      named: "Views/Sessions/SessionWindowView+ColumnPolicies.swift"
    )
    let presentationSource = try previewableSourceFile(
      named: "Views/Sessions/SessionWindowView+Presentation.swift"
    )
    let columnsSource = try previewableSourceFile(
      named: "Views/Sessions/SessionWindowView+Columns.swift"
    )

    #expect(policySource.contains("var decisionsRefreshTrigger: SessionDecisionDataKey"))
    #expect(policySource.contains("var decisionFilterTrigger: SessionDecisionFilterSnapshot"))
    #expect(presentationSource.contains(".task(id: decisionsRefreshTrigger)"))
    #expect(presentationSource.contains("await refreshDecisionsCache()"))
    #expect(presentationSource.contains(".task(id: decisionFilterTrigger)"))
    #expect(presentationSource.contains("await refilterDecisionsCache()"))
    #expect(columnsSource.contains("func refreshDecisionsCache() async"))
    #expect(columnsSource.contains("stateCache.decisionRuntime.reloadAuditEvents("))
    #expect(columnsSource.contains("func refilterDecisionsCache() async"))
  }

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
      named: "Views/Sessions/SessionWindowStandardLayout.swift")

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
    #expect(toolbarSource.contains("if shouldRenderShortcutOverlay"))
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
