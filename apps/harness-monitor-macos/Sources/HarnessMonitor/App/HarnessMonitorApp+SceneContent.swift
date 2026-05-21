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
        mcpWindowCommandRegistrar: appMCPWindowCommandRegistrar,
        sessionWindowPresenceTracker: appSessionWindowPresenceTracker,
        initialRoute: initialSessionWindowRoute,
        themeMode: themeModeBinding,
        perfScenario: perfScenario,
        perfScenarioStatus: perfScenarioStatusBinding,
        perfScenarioFailureReason: perfScenarioFailureReasonBinding
      )
      .harnessTrackMCPWindow()
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
    } else {
      Color.clear.accessibilityHidden(true)
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
      .harnessTrackMCPWindow(tracksElements: false)
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
      .harnessTrackMCPWindow()
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
      mcpWindowCommandRegistrar: appMCPWindowCommandRegistrar,
      themeMode: themeModeBinding,
      settingsSelectedSection: settingsSelectedSectionBinding,
      settingsNavigationRequest: settingsNavigationRequestBinding,
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
}
