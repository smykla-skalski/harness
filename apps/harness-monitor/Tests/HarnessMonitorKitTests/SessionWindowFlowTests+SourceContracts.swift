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

  @Test("New Session success dismisses first and then opens the created session window")
  func newSessionSuccessUsesSwiftUIWindowRouting() throws {
    let source = try previewableSourceFile(named: "Views/NewSession/NewSessionSheetView.swift")

    #expect(!source.contains("import AppKit"))
    #expect(source.contains("@Environment(\\.dismiss)"))
    #expect(source.contains("@Environment(\\.openWindow)"))
    #expect(
      source.contains(
        "openWindow.openHarnessSessionWindow(sessionID: startedSession.sessionId)"
      )
    )
    #expect(source.contains("await Task.yield()"))
    #expect(source.contains("dismiss()"))
    #expect(!source.contains("NSApplication"))
    #expect(!source.contains("NSWindow"))
    #expect(!source.contains("makeKeyAndOrderFront"))
  }

  @Test("Debugging OCR paste uses SwiftUI paste command routing")
  func debuggingOCRPasteUsesSwiftUIPasteCommandRouting() throws {
    let pasteCommandSource = try previewableSourceFile(
      named: "Views/Dashboard/DashboardDebuggingOCRPasteCommand.swift"
    )
    let routeSource = try previewableSourceFile(
      named: "Views/Dashboard/DashboardDebuggingRouteView.swift"
    )
    let controlsSource = try previewableSourceFile(
      named: "Views/Dashboard/DashboardDebuggingOCRControls.swift"
    )
    let recentsSource = try previewableSourceFile(
      named: "Views/Dashboard/DashboardDebuggingOCRRecents.swift"
    )
    let previewSource = try previewableSourceFile(
      named: "Views/Dashboard/DashboardDebuggingOCRPreview.swift"
    )
    let postProcessingSource = try previewableSourceFile(
      named: "Views/Dashboard/DashboardDebuggingOCRPostProcessing.swift"
    )
    let screenshotsSource = try previewableSourceFile(
      named: "Views/Dashboard/DashboardDebuggingOCRScreenshots.swift"
    )
    let sceneContentSource = try harnessSourceFile(
      named: "App/HarnessMonitorApp+SceneContent.swift"
    )

    #expect(pasteCommandSource.contains(".pasteDestination("))
    #expect(pasteCommandSource.contains("DashboardOCRTransferImage.self"))
    #expect(pasteCommandSource.contains("NSEvent.addLocalMonitorForEvents"))
    #expect(pasteCommandSource.contains("requestPasteFromClipboard()"))
    #expect(pasteCommandSource.contains("requestDashboardRoute(.debugging)"))
    #expect(!pasteCommandSource.contains("@objc"))
    #expect(!pasteCommandSource.contains("NSResponder"))
    #expect(routeSource.contains("DashboardDiagnosticsSection(title: \"OCR\")"))
    #expect(routeSource.contains("DashboardOCRSummaryText.make("))
    #expect(!routeSource.contains("Text(summaryText)"))
    #expect(!routeSource.contains("Label(\"No Images\""))
    #expect(routeSource.contains("items.insert(contentsOf: newItems, at: 0)"))
    #expect(routeSource.contains("DashboardOCRPasteFeedbackView"))
    #expect(routeSource.contains(".sensoryFeedback("))
    #expect(routeSource.contains(".impact(weight: .medium, intensity: 0.85)"))
    #expect(controlsSource.contains(".symbolEffect("))
    #expect(controlsSource.contains(".bounce.up.wholeSymbol"))
    #expect(routeSource.contains("DashboardOCRRecentImagesSection"))
    #expect(routeSource.contains("DashboardOCRSystemScreenshotsSection"))
    #expect(routeSource.contains("allowedContentTypes: [.folder]"))
    #expect(routeSource.contains("recentStore.record(newItems + updatedExistingItems)"))
    #expect(routeSource.contains("mergeSourceMetadata(from: candidate)"))
    #expect(routeSource.contains("recentStore.record([updatedItem])"))
    #expect(postProcessingSource.contains("DashboardOCRTextSourceProfile"))
    #expect(postProcessingSource.contains("case slack"))
    #expect(postProcessingSource.contains("normalizeURLs"))
    #expect(screenshotsSource.contains("DispatchSource.makeFileSystemObjectSource"))
    #expect(screenshotsSource.contains("beginSecurityScope()"))
    #expect(screenshotsSource.contains("HARNESS_MONITOR_DEBUGGING_OCR_SCREENSHOT_FOLDER"))
    #expect(screenshotsSource.contains("contentType.conforms(to: .image)"))
    #expect(controlsSource.contains("Button(action: onChooseImages)"))
    #expect(controlsSource.contains("DashboardOCRDropZoneButtonStyle"))
    #expect(controlsSource.contains(".pointerStyle(.link)"))
    #expect(!controlsSource.contains("NSCursor"))
    #expect(recentsSource.contains("ScrollView(.horizontal, showsIndicators: false)"))
    #expect(recentsSource.contains(".aspectRatio(contentMode: .fill)"))
    #expect(routeSource.contains("sourceMetadata: item.sourceMetadata"))
    #expect(recentsSource.contains("recognizedText: item.recognizedText"))
    #expect(previewSource.contains("NSScreen.main?.visibleFrame.size"))
    #expect(previewSource.contains("idealWindowSize(fitting visibleSize"))
    #expect(previewSource.contains("func displaySize(fitting availableSize"))
    #expect(previewSource.contains("init(recentImage: DashboardOCRRecentImage)"))
    #expect(previewSource.contains("Text(\"Scanned Text\")"))
    #expect(previewSource.contains("recognizedTextBodyMaximumHeight"))
    #expect(previewSource.contains(".frame(height: bodyHeight)"))
    #expect(previewSource.contains("dashboardDebuggingOCRPreviewText"))
    #expect(sceneContentSource.contains(".dashboardDebuggingOCRPasteCommand()"))
  }

  @Test("Session tabs route through SwiftUI commands plus the tabbing accessor")
  func sessionTabsUseSwiftUISceneCommands() throws {
    let appSource = try harnessSourceFile(named: "App/HarnessMonitorApp.swift")
    let scenesSource = try harnessSourceFile(named: "App/HarnessMonitorApp+Scenes.swift")
    let sceneContentSource = try harnessSourceFile(
      named: "App/HarnessMonitorApp+SceneContent.swift")
    let routerSource = try harnessSourceFile(named: "App/HarnessMonitorInitialWindowRouter.swift")
    let replayerSource = try harnessSourceFile(named: "App/SessionWindowTabGroupReplayer.swift")
    let rootSource = try harnessSourceFile(named: "App/SessionWindowRootView.swift")
    let commandsSource = try harnessSourceFile(named: "Commands/WindowMenuCommands.swift")
    let tabbingAccessorPath = harnessSourceURL(named: "App/SessionWindowTabbing.swift").path
    let tabbingSource = try harnessSourceFile(named: "App/SessionWindowTabbing.swift")
    let toolbarGlassSource = try previewableSourceFile(
      named: "Support/ToolbarGlassStateMonitor.swift"
    )
    let settingsSource = try previewableSourceFile(named: "Views/Settings/SettingsView.swift")
      + previewableSourceFile(named: "Views/Settings/SettingsView+SectionSwitch.swift")
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
    #expect(rootSource.contains("windowToolbarBackgroundVisibility: .automatic"))
    #expect(!rootSource.contains("windowToolbarBackgroundVisibility: .visible"))
    #expect(!rootSource.contains("windowToolbarBackgroundVisibility: .hidden"))
    #expect(!rootSource.contains("titlebarAppearsTransparent: true"))
    #expect(
      rootSource.contains(
        "HarnessMonitorAccessibility.sessionWindowToolbarSeparatorSuppressed"
      )
    )
    #expect(tabbingSource.contains("scheduleWindowTabbingApplication()"))
    #expect(tabbingSource.contains("await Task.yield()"))
    #expect(tabbingSource.contains("SessionWindowTabbingSupport.prepareWindowForTabbing("))
    #expect(!tabbingSource.contains("guard window.toolbar != nil else"))
    #expect(tabbingSource.contains("window.tab.attributedTitle"))
    #expect(tabbingSource.contains("titlebarSeparatorStyle"))
    #expect(tabbingSource.contains("titlebarAppearsTransparent"))
    #expect(toolbarGlassSource.contains("let titlebarAppearsTransparent: Bool"))
    #expect(
      toolbarGlassSource.contains(
        "window.titlebarAppearsTransparent = titlebarAppearsTransparent"
      )
    )
    #expect(settingsSource.contains("settingsToolbarSeparatorSuppressed"))
    #expect(settingsSource.contains("titlebarAppearsTransparent: true"))
    #expect(settingsSource.contains(".harnessMonitorBackgroundExtensionEffect()"))
    #expect(routerSource.contains("SessionWindowTabGroupReplayer.replay("))
    #expect(replayerSource.contains("let tabReadyWindows = grouping.sessionIDs.compactMap"))
    #expect(replayerSource.contains("isWindowTabReady"))
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
        "public func openHarnessDashboardWindow(mergeIfNeeded: Bool)"
      )
    )
    #expect(
      openActionSource.contains(
        """
        public func openHarnessSessionWindow(
            sessionID: String,
            mergeIfNeeded: Bool
        """
      )
    )
    #expect(
      openActionSource.contains(
        """
        guard let sessionID, !sessionID.isEmpty else {
              openHarnessDashboardWindow()
        """
      )
    )
    #expect(openActionSource.contains("mergeNewestTabbedWindowIfNeeded"))
    #expect(windowCommandsSource.contains("openWindow.openHarnessDashboardWindow()"))
    #expect(recentCommandsSource.contains("openWindow.openHarnessDashboardWindow()"))
    #expect(
      routingSource.contains(
        "openWindow.openHarnessDashboardWindow(mergeIfNeeded: mergeIfNeeded)"
      )
    )
    #expect(
      routingSource.contains(
        """
        openWindow.openHarnessSessionWindow(
                  sessionID: sessionID,
                  mergeIfNeeded: mergeIfNeeded
        """
      )
    )
    #expect(menuBarSource.contains("openWindow.openHarnessDashboardWindow()"))
    #expect(unavailableSource.contains("openWindow.openHarnessDashboardWindow()"))
  }

  @Test("Dashboard window open-at-quit state is mirrored end-to-end")
  func dashboardWindowOpenAtQuitStateIsMirroredEndToEnd() throws {
    let sceneContentSource = try harnessSourceFile(
      named: "App/HarnessMonitorApp+SceneContent.swift")
    let bindingSource = try harnessSourceFile(named: "App/DashboardWindowAppKitBinding.swift")
    let modifierSource = try harnessSourceFile(named: "App/DashboardWindowLifecycleModifier.swift")
    let trackerSource = try harnessSourceFile(named: "App/DashboardWindowLifecycleTracker.swift")
    let delegateSource = try harnessSourceFile(named: "App/HarnessMonitorAppDelegate.swift")
    let routerSource = try harnessSourceFile(named: "App/HarnessMonitorInitialWindowRouter.swift")

    #expect(sceneContentSource.contains(".modifier(DashboardWindowAppKitBinding())"))
    #expect(sceneContentSource.contains(".modifier(DashboardWindowLifecycleModifier())"))
    #expect(bindingSource.contains("DashboardWindowAppKitRegistry.shared.bind(window: window)"))
    #expect(
      bindingSource.contains(
        "DashboardWindowAppKitRegistry.shared.unbind(window: currentWindow)"
      )
    )
    #expect(modifierSource.contains("DashboardWindowLifecycleTracker.shared.markOpen()"))
    #expect(modifierSource.contains("DashboardWindowLifecycleTracker.shared.markClosed()"))
    #expect(trackerSource.contains("static let openAtQuitKey"))
    #expect(trackerSource.contains("static let tabbedSessionIDsAtQuitKey"))
    #expect(trackerSource.contains("static let wasForegroundTabAtQuitKey"))
    #expect(trackerSource.contains("func flushOpenAtQuit("))
    #expect(trackerSource.contains("static func wasOpenAtQuit("))
    #expect(trackerSource.contains("static func tabRestoreStateAtQuit("))
    #expect(
      delegateSource.contains(
        "DashboardWindowLifecycleTracker.shared.flushOpenAtQuit()"
      )
    )
    #expect(routerSource.contains("DashboardWindowLifecycleTracker.wasOpenAtQuit()"))
    #expect(routerSource.contains("DashboardWindowLifecycleTracker.tabRestoreStateAtQuit()"))
  }

  @Test("Settings window opts out of AppKit restoration")
  func settingsWindowDisablesAppKitRestoration() throws {
    let scenesSource = try harnessSourceFile(named: "App/HarnessMonitorApp+Scenes.swift")
    let startRange = try #require(scenesSource.range(of: "var settingsWindowScene: some Scene"))
    let endRange =
      try #require(scenesSource.range(of: "var policyCanvasLabWindowScene: some Scene"))
    let settingsSceneSource = String(scenesSource[startRange.lowerBound..<endRange.lowerBound])

    #expect(
      settingsSceneSource.contains("Window(\"Settings\", id: HarnessMonitorWindowID.settings)")
    )
    #expect(settingsSceneSource.contains(".restorationBehavior(.disabled)"))
    #expect(!settingsSceneSource.contains("allowsWindowRestoration ? .automatic : .disabled"))
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

}
