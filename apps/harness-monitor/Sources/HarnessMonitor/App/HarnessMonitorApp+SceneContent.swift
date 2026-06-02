import HarnessMonitorKit
import HarnessMonitorUIPreviewable
import SwiftUI

extension HarnessMonitorApp {
  // The Xcode preview shell injects the canvas view directly into an
  // NSPreviewTargetWindow; mounting the live root content from the App's
  // WindowGroups also lights up `.trackWindow`, SwiftData-backed children,
  // and notification observers, all of which dispatch main-actor work that
  // the preview agent reaps off-main and crashes with `BUG IN CLIENT OF
  // LIBDISPATCH`. The UI-test host also launches in `.preview`, but it still
  // needs the full scene tree so XCUITest can exercise the app.
  var rendersLiveSceneContent: Bool {
    launchMode == .live || isUITesting
  }

  var rendersPolicyCanvasLabOnly: Bool {
    showsPolicyCanvasLab && !isUITesting
  }

  var rendersPolicyCanvasLabContent: Bool {
    rendersLiveSceneContent || rendersPolicyCanvasLabOnly
  }

  var rendersMenuBarExtraContent: Bool {
    (launchMode == .live && !isTestRun) || isUITesting
  }

  var allowsWindowRestoration: Bool {
    launchMode == .live && !isTestRun
  }

  @ViewBuilder
  func sessionWindowSceneContent(
    token: Binding<SessionWindowToken?>
  ) -> some View {
    if rendersLiveSceneContent, let tokenValue = token.wrappedValue {
      SessionWindowRootView(
        token: tokenValue,
        store: appStore,
        notifications: notificationController,
        acpAttentionState: acpAttentionState,
        keyWindowObserver: keyWindowObserver,
        windowCommandRouting: appWindowCommandRouting,
        windowNavigationHistory: appWindowNavigationHistory,
        mcpWindowCommandRegistrar: appMCPWindowCommandRegistrar,
        sessionWindowPresenceTracker: appSessionWindowPresenceTracker,
        initialRoute: initialSessionWindowRoute,
        themeMode: themeModeBinding,
        perfScenario: perfScenario,
        perfScenarioStatus: perfScenarioStatusBinding,
        perfScenarioFailureReason: perfScenarioFailureReasonBinding
      )
      .harnessTrackMCPWindow()
      .environment(appStore)
      .dashboardDebuggingOCRPasteCommand()
    } else {
      Color.clear.accessibilityHidden(true)
    }
  }

  @ViewBuilder var dashboardWindowSceneContent: some View {
    if rendersLiveSceneContent {
      dashboardWindowContent
        .modifier(DashboardWindowAppKitBinding())
        .modifier(SessionWindowTabbing(role: .dashboard))
        .modifier(DashboardWindowLifecycleModifier())
        .harnessTrackMCPWindow()
        .environment(appStore)
        .environment(\.openAnythingDashboardReviewRegistry, appOpenAnythingReviews)
        .dashboardDebuggingOCRPasteCommand()
        .onOpenURL { url in
          handleHarnessDeepLink(url)
        }
    } else {
      Color.clear.accessibilityHidden(true)
    }
  }

  /// Bridges incoming `harness://` URLs into the running app's selection
  /// surfaces. Pull-request links route through the existing Open Anything
  /// review registry so the dashboard's selection plumbing is reused; review
  /// and task-board routes are reserved for follow-up units that wire route
  /// switching and per-route scene storage.
  func handleHarnessDeepLink(_ url: URL) {
    guard let route = HarnessMonitorDeepLinkRouter.parse(url: url) else { return }
    switch route {
    case .pullRequest(let id, let file):
      // The review registry carries the optional file path and line range so
      // the reviews route can jump straight into Files mode at the right lines.
      appOpenAnythingReviews.requestSelection(
        pullRequestID: id,
        filePath: file?.path,
        lineSelection: file?.lines
      )
    case .reviews, .taskBoard:
      // Route switching into reviews/taskBoard is deferred (intents-foundation Unit 2):
      // once the deep-link router can drive `selectedRoute` + `needsMeOn` SceneStorage.
      break
    }
  }

  @ViewBuilder var settingsSceneContent: some View {
    if rendersLiveSceneContent {
      HarnessMonitorSettingsRootView(
        store: appStore,
        notifications: notificationController,
        acpAttentionState: acpAttentionState,
        windowCommandRouting: appWindowCommandRouting,
        windowNavigationHistory: appWindowNavigationHistory,
        mcpWindowCommandRegistrar: appMCPWindowCommandRegistrar,
        mobileRelayRuntime: mobileRelayRuntime,
        themeMode: themeModeBinding,
        selectedSection: settingsSelectedSectionBinding,
        navigationRequest: settingsNavigationRequestBinding
      )
      .harnessTrackMCPWindow(tracksElements: false)
      .environment(appStore)
      .environment(\.supervisorAuditTimelineDispatcher, appAuditTimelineDispatcher)
      .dashboardDebuggingOCRPasteCommand()
    } else {
      Color.clear.accessibilityHidden(true)
    }
  }

  @ViewBuilder var policyCanvasLabWindowSceneContent: some View {
    if rendersPolicyCanvasLabContent {
      PolicyCanvasLabSceneHost(
        store: appStore,
        keyWindowObserver: keyWindowObserver,
        windowCommandRouting: appWindowCommandRouting,
        mcpWindowCommandRegistrar: appMCPWindowCommandRegistrar,
        allowsLiveBootstrap: !rendersPolicyCanvasLabOnly,
        themeMode: themeModeBinding
      )
    } else {
      Color.clear.accessibilityHidden(true)
    }
  }

  @ViewBuilder private var dashboardWindowContent: some View {
    HarnessMonitorDashboardWindowContent(
      delegate: appDelegate,
      store: appStore,
      notifications: notificationController,
      keyWindowObserver: keyWindowObserver,
      acpAttentionState: acpAttentionState,
      windowCommandRouting: appWindowCommandRouting,
      windowNavigationHistory: appWindowNavigationHistory,
      mcpWindowCommandRegistrar: appMCPWindowCommandRegistrar,
      themeMode: themeModeBinding,
      settingsSelectedSection: settingsSelectedSectionBinding,
      settingsNavigationRequest: settingsNavigationRequestBinding,
      supervisorAuditTimelineDispatcher: appAuditTimelineDispatcher,
      perfScenario: perfScenario,
      hasRunPerfScenario: hasRunPerfScenarioBinding,
      perfScenarioStatus: perfScenarioStatusBinding,
      perfScenarioFailureReason: perfScenarioFailureReasonBinding,
      defersInitialContentUntilBootstrap: defersInitialMainWindowUntilBootstrap,
      presentOpenAnything: { presentOpenAnythingPalette() },
      setOpenAnythingQuery: { appOpenAnythingPalette.query = $0 },
      container: container
    )
    .onChange(of: appStore.openFolderRequest) { _, _ in
      presentOpenFolder()
    }
    .attachExternalSessionImporter(store: appStore)
  }

  var openAnythingExecutorBinder: HarnessMonitorOpenAnythingExecutorBinder {
    HarnessMonitorOpenAnythingExecutorBinder(
      controller: appOpenAnythingPaletteController,
      reviewRegistry: appOpenAnythingReviews,
      store: appStore,
      windowNavigationHistory: appWindowNavigationHistory,
      showsPolicyCanvasLab: showsPolicyCanvasLab,
      refreshStore: refreshStore,
      settingsSelectedSection: settingsSelectedSectionBinding,
      settingsNavigationRequest: settingsNavigationRequestBinding,
      hasBound: hasBoundOpenAnythingExecutorBinding
    )
  }

  var openAnythingAppServiceHost: some View {
    // Initial window routing can restore only session windows, so the
    // single-instance Open Anything driver cannot depend on the dashboard
    // scene mounting first. The menu bar scene is present for every live app
    // run, making it the stable place to keep corpus updates, executor
    // binding, and global hot-key registration alive.
    openAnythingEngineHost
      .modifier(openAnythingExecutorBinder)
  }

  private var openAnythingEngineHost: some View {
    OpenAnythingEngineHost(
      coordinator: appOpenAnythingCoordinator,
      store: appStore,
      reviewRegistry: appOpenAnythingReviews,
      showsPolicyCanvasLab: showsPolicyCanvasLab,
      loadedSessionOverride: appOpenAnythingLoadedSessionOverride,
      globalHotKeyController: appGlobalHotKeyController,
      globalHotKeyEnabled: globalOpenAnythingHotKeyEnabled,
      globalHotKeyDescriptorStorage: globalOpenAnythingHotKeyDescriptor,
      presentPalette: { presentOpenAnythingPalette() }
    )
  }
}
