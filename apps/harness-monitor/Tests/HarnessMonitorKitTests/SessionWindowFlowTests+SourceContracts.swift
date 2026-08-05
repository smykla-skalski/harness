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

  @Test("Open Recent close-after-pick routes into Dashboard")
  func openRecentCloseAfterPickUsesCurrentWindowDismiss() throws {
    let source = try previewableSourceFile(named: "Views/Sessions/OpenRecentView.swift")

    #expect(!source.contains("import AppKit"))
    #expect(source.contains("@Environment(\\.dismiss)"))
    #expect(source.contains("@Environment(\\.openWindow)"))
    #expect(source.contains("openWindow.openHarnessDashboardAgent"))
    #expect(!source.contains("openWindow.openHarnessSessionWindow"))
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

  @Test("New Session success dismisses first and then routes into Dashboard")
  func newSessionSuccessUsesSwiftUIWindowRouting() throws {
    let source = try previewableSourceFile(named: "Views/NewSession/NewSessionSheetView.swift")

    #expect(!source.contains("import AppKit"))
    #expect(source.contains("@Environment(\\.dismiss)"))
    #expect(source.contains("@Environment(\\.openWindow)"))
    #expect(
      source.contains(
        "openWindow.openHarnessDashboardAgent(.session(sessionID: startedSession.sessionId))"
      )
    )
    #expect(source.contains("await Task.yield()"))
    #expect(source.contains("dismiss()"))
    #expect(!source.contains("NSApplication"))
    #expect(!source.contains("NSWindow"))
    #expect(!source.contains("makeKeyAndOrderFront"))
  }

  @Test("Production scenes contain only Dashboard and Settings windows")
  func productionScenesExcludeSessionWindowsAndTabs() throws {
    let appSource = try harnessSourceFile(named: "App/HarnessMonitorApp.swift")
    let scenesSource = try harnessSourceFile(named: "App/HarnessMonitorApp+Scenes.swift")
    let sceneContentSource = try harnessSourceFile(
      named: "App/HarnessMonitorApp+SceneContent.swift")
    let commandsSource = try harnessSourceFile(named: "Commands/WindowMenuCommands.swift")
    let settingsSource =
      try previewableSourceFile(named: "Views/Settings/SettingsView.swift")
      + previewableSourceFile(named: "Views/Settings/SettingsView+SectionSwitch.swift")
    let appRoot = harnessSourceURL(named: "App/HarnessMonitorApp.swift")
      .deletingLastPathComponent()

    #expect(appSource.contains("dashboardWindowScene"))
    #expect(appSource.contains("settingsWindowScene"))
    #expect(!appSource.contains("sessionWindowScene"))
    #expect(scenesSource.contains("Window("))
    #expect(!scenesSource.contains("WindowGroup("))
    #expect(scenesSource.contains("id: HarnessMonitorWindowID.dashboard"))
    #expect(scenesSource.contains("id: HarnessMonitorWindowID.settings"))
    #expect(!scenesSource.contains("HarnessMonitorWindowID.sessionScene"))
    #expect(!scenesSource.contains("SessionWindowToken"))
    #expect(
      scenesSource.contains(
        ".restorationBehavior(allowsWindowRestoration ? .automatic : .disabled)"
      )
    )
    #expect(scenesSource.contains(".restorationBehavior(.disabled)"))
    #expect(!sceneContentSource.contains("SessionWindowTabbing"))
    #expect(commandsSource.contains("@Environment(\\.openWindow)"))
    #expect(commandsSource.contains("openHarnessDashboardWindow"))
    #expect(!commandsSource.contains("openHarnessSessionWindow"))
    #expect(settingsSource.contains("settingsToolbarSeparatorSuppressed"))
    #expect(settingsSource.contains("titlebarAppearsTransparent: true"))
    #expect(settingsSource.contains(".harnessMonitorBackgroundExtensionEffect()"))
    #expect(
      !FileManager.default.fileExists(
        atPath: appRoot.appendingPathComponent("SessionWindowRootView.swift").path
      )
    )
    #expect(
      !FileManager.default.fileExists(
        atPath: appRoot.appendingPathComponent("SessionWindowTabbing.swift").path
      )
    )
  }

  @Test("Dashboard window routing has no Session fallback")
  func dashboardWindowRoutingHasNoSessionFallback() throws {
    let routingSource = try harnessSourceFile(
      named: "App/HarnessMonitorApp+InitialWindowRouting.swift"
    )
    let menuBarSource = try harnessSourceFile(named: "App/HarnessMonitorMenuBarExtra.swift")
    let windowCommandsSource = try harnessSourceFile(named: "Commands/WindowMenuCommands.swift")
    let openActionSource = try previewableSourceFile(
      named: "Support/DashboardWindowOpenAction.swift"
    )
    let unavailableSource = try previewableSourceFile(
      named: "Views/Sessions/SessionWindowView+Unavailable.swift"
    )

    #expect(openActionSource.contains("public func openHarnessDashboardWindow()"))
    #expect(openActionSource.contains("public func openHarnessDashboardAgent"))
    #expect(!openActionSource.contains("openHarnessSessionWindow"))
    #expect(!openActionSource.contains("mergeNewestTabbedWindowIfNeeded"))
    #expect(windowCommandsSource.contains("openWindow.openHarnessDashboardWindow()"))
    #expect(routingSource.contains("openWindow.openHarnessDashboardWindow()"))
    #expect(!routingSource.contains("openHarnessSessionWindow"))
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

    #expect(!sceneContentSource.contains("DashboardWindowAppKitBinding"))
    #expect(sceneContentSource.contains(".modifier(DashboardWindowLifecycleModifier())"))
    #expect(modifierSource.contains("DashboardWindowLifecycleTracker.shared.markOpen()"))
    #expect(modifierSource.contains("DashboardWindowLifecycleTracker.shared.markClosed()"))
    #expect(trackerSource.contains("static let openAtQuitKey"))
    #expect(trackerSource.contains("func flushOpenAtQuit("))
    #expect(trackerSource.contains("static func restoreStateAtQuit("))
    #expect(
      delegateSource.contains(
        "DashboardWindowLifecycleTracker.shared.flushOpenAtQuit()"
      )
    )
    #expect(routerSource.contains("DashboardWindowLifecycleTracker.restoreStateAtQuit("))
  }

  @Test("Session window scene is absent from production")
  func sessionWindowSceneIsAbsent() throws {
    let scenesSource = try harnessSourceFile(named: "App/HarnessMonitorApp+Scenes.swift")
    #expect(!scenesSource.contains("var sessionWindowScene"))
    #expect(!scenesSource.contains("HarnessMonitorWindowID.sessionScene"))
    #expect(!scenesSource.contains("SessionWindowToken"))
  }

  @Test("Launch and termination paths retain no Session restoration work")
  func launchAndTerminationPathsRetainNoSessionRestorationWork() throws {
    let routerSource = try harnessSourceFile(named: "App/HarnessMonitorInitialWindowRouter.swift")
    let delegateSource = try harnessSourceFile(named: "App/HarnessMonitorAppDelegate.swift")
    let lifecycleSource = try harnessKitSourceFile(
      named: "Stores/HarnessMonitorStore+AppLifecycle.swift"
    )

    #expect(!routerSource.contains("openHarnessSessionWindow"))
    #expect(!routerSource.contains("SessionWindowQuitCapture"))
    #expect(!delegateSource.contains("SessionWindowQuitCapture"))
    #expect(!delegateSource.contains("persistSessionWindowRestoreSnapshot"))
    #expect(!delegateSource.contains("beginSessionWindowTerminationSnapshot"))
    #expect(!lifecycleSource.contains("flushSessionWindowsOpenAtQuit"))
  }

  @Test("Settings window opts out of AppKit restoration")
  func settingsWindowDisablesAppKitRestoration() throws {
    let scenesSource = try harnessSourceFile(named: "App/HarnessMonitorApp+Scenes.swift")
    let startRange = try #require(scenesSource.range(of: "var settingsWindowScene: some Scene"))
    let endRange =
      try #require(scenesSource.range(of: "var menuBarExtraScene: some Scene"))
    let settingsSceneSource = String(scenesSource[startRange.lowerBound..<endRange.lowerBound])

    #expect(
      settingsSceneSource.contains("Window(\"Settings\", id: HarnessMonitorWindowID.settings)")
    )
    #expect(settingsSceneSource.contains(".restorationBehavior(.disabled)"))
    #expect(!settingsSceneSource.contains("allowsWindowRestoration ? .automatic : .disabled"))
  }

  @Test("Supported navigation paths do not open Session windows")
  func supportedNavigationPathsDoNotOpenSessionWindows() throws {
    let roots = [
      repoRoot().appendingPathComponent("apps/harness-monitor/Sources/HarnessMonitor"),
      repoRoot().appendingPathComponent(
        "apps/harness-monitor/Sources/HarnessMonitorUIPreviewable"
      ),
    ]
    var offenders: [String] = []
    for root in roots {
      let enumerator = try #require(
        FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)
      )
      for case let fileURL as URL in enumerator where fileURL.pathExtension == "swift" {
        let source = try String(contentsOf: fileURL, encoding: .utf8)
        guard source.contains("openHarnessSessionWindow") else { continue }
        offenders.append(fileURL.path)
      }
    }

    #expect(offenders.isEmpty)
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
