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
      .modifier(
        openAnythingHostModifier(
          windowID: HarnessMonitorWindowID.sessionWindow(tokenValue.sessionID)
        )
      )
      .harnessTrackMCPWindow()
      .environment(appStore)
    } else {
      Color.clear.accessibilityHidden(true)
    }
  }

  @ViewBuilder var dashboardWindowSceneContent: some View {
    if rendersLiveSceneContent {
      dashboardWindowContent
        .modifier(openAnythingHostModifier(windowID: HarnessMonitorWindowID.dashboard))
        .background {
          // Dashboard is always present in a live session and outlives every
          // other window, so it is the right place to mount the single-instance
          // engine driver that owns corpus rebuilds and Carbon hot-key
          // registration. Mounting on per-window host modifiers caused N-way
          // duplication.
          openAnythingEngineHost
        }
        .modifier(DashboardWindowAppKitBinding())
        .modifier(SessionWindowTabbing(role: .dashboard))
        .modifier(DashboardWindowLifecycleModifier())
        .harnessTrackMCPWindow()
        .environment(appStore)
        .environment(\.openAnythingDashboardReviewRegistry, appOpenAnythingReviews)
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
    case .pullRequest(let id):
      appOpenAnythingReviews.requestSelection(pullRequestID: id)
    case .reviews, .taskBoard:
      // TODO(intents-foundation): wire route switching once the deep-link
      // router can drive `selectedRoute` + `needsMeOn` SceneStorage. The URL
      // scheme is registered and parsed; only the dispatch into route state
      // is deferred to Unit 2.
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
        mcpWindowCommandRegistrar: appMCPWindowCommandRegistrar,
        themeMode: themeModeBinding,
        selectedSection: settingsSelectedSectionBinding,
        navigationRequest: settingsNavigationRequestBinding
      )
      .modifier(openAnythingHostModifier(windowID: HarnessMonitorWindowID.settings))
      .harnessTrackMCPWindow(tracksElements: false)
      .environment(appStore)
      .environment(\.supervisorAuditTimelineDispatcher, appAuditTimelineDispatcher)
    } else {
      Color.clear.accessibilityHidden(true)
    }
  }

  @ViewBuilder var policyCanvasLabWindowSceneContent: some View {
    if rendersLiveSceneContent {
      PolicyCanvasLabWindowView(
        store: appStore,
        keyWindowObserver: keyWindowObserver,
        windowCommandRouting: appWindowCommandRouting,
        mcpWindowCommandRegistrar: appMCPWindowCommandRegistrar,
        themeMode: themeModeBinding
      )
      .modifier(openAnythingHostModifier(windowID: HarnessMonitorWindowID.policyCanvasLab))
      .harnessTrackMCPWindow()
      .environment(appStore)
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
      container: container
    )
    .onChange(of: appStore.openFolderRequest) { _, _ in
      presentOpenFolder()
    }
    .attachExternalSessionImporter(store: appStore)
  }

  func openAnythingHostModifier(windowID: String) -> HarnessMonitorOpenAnythingHostModifier {
    HarnessMonitorOpenAnythingHostModifier(
      windowID: windowID,
      model: appOpenAnythingPalette,
      reviewRegistry: appOpenAnythingReviews,
      store: appStore,
      keyWindowObserver: keyWindowObserver,
      windowNavigationHistory: appWindowNavigationHistory,
      showsPolicyCanvasLab: showsPolicyCanvasLab,
      refreshStore: refreshStore,
      settingsSelectedSection: settingsSelectedSectionBinding,
      settingsNavigationRequest: settingsNavigationRequestBinding
    )
  }

  private var openAnythingEngineHost: some View {
    OpenAnythingEngineHost(
      coordinator: appOpenAnythingCoordinator,
      store: appStore,
      reviewRegistry: appOpenAnythingReviews,
      showsPolicyCanvasLab: showsPolicyCanvasLab,
      globalHotKeyController: appGlobalHotKeyController,
      globalHotKeyEnabled: globalOpenAnythingHotKeyEnabled,
      globalHotKeyDescriptorStorage: globalOpenAnythingHotKeyDescriptor,
      presentPalette: { presentOpenAnythingPalette() }
    )
  }
}
