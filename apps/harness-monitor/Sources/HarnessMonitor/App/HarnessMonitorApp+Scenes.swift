import HarnessMonitorKit
import HarnessMonitorUIPreviewable
import SwiftUI

extension HarnessMonitorApp {
  var dashboardWindowScene: some Scene {
    Window(
      "Dashboard",
      id: HarnessMonitorWindowID.dashboard
    ) {
      dashboardWindowSceneContent
    }
    .windowToolbarStyle(.unified)
    .defaultSize(width: mainWindowDefaultSize.width, height: mainWindowDefaultSize.height)
    .windowResizability(.contentMinSize)
    .restorationBehavior(allowsWindowRestoration ? .automatic : .disabled)
    .defaultLaunchBehavior(shouldHandleInitialWindowRouting ? .suppressed : .automatic)
    .onChange(of: scenePhase, initial: true) { _, _ in
      installMainWindowLauncherIfNeeded()
      installAppSceneServicesIfNeeded()
      scheduleInitialWindowRoutingIfNeeded()
    }
    .onChange(of: globalOpenAnythingHotKeyEnabled, initial: true) { _, _ in
      installAppSceneServicesIfNeeded()
      syncOpenAnythingGlobalHotKey()
    }
    .onChange(of: globalOpenAnythingHotKeyDescriptor, initial: true) { _, _ in
      installAppSceneServicesIfNeeded()
      syncOpenAnythingGlobalHotKey()
    }
    .commands {
      mainWindowCommands
    }
  }

  var settingsWindowScene: some Scene {
    Window("Settings", id: HarnessMonitorWindowID.settings) {
      settingsSceneContent
    }
    .windowStyle(.titleBar)
    .defaultSize(width: 860, height: 620)
    .restorationBehavior(.disabled)
  }

  var menuBarExtraScene: some Scene {
    // SwiftUI owns the status-item scene; keep dynamic state to asset-catalog
    // image names so the inserted MenuBarExtra stays stable.
    MenuBarExtra(
      isInserted: .constant(rendersMenuBarExtraContent)
    ) {
      HarnessMonitorMenuBarExtraContent(
        store: appStore,
        openPolicyWorkspace: {
          appWindowNavigationHistory.requestDashboardRoute(.policyCanvas)
          openWindow(id: HarnessMonitorWindowID.dashboard)
        }
      )
    } label: {
      menuBarExtraLabel
    }
    .menuBarExtraStyle(.menu)
  }

  @CommandsBuilder private var mainWindowCommands: some Commands {
    HarnessMonitorMainCommandSet(
      store: appStore,
      textSizeIndex: textSizeIndex,
      increaseTextSize: increaseTextSize,
      decreaseTextSize: decreaseTextSize,
      resetTextSize: resetTextSize,
      refreshStore: refreshStore,
      presentOpenAnything: presentOpenAnythingPalette,
      openAnythingCorpusSize: { appOpenAnythingPalette.recordCount }
    )
  }

  private var menuBarStatusItemImageName: String {
    appMenuBarStatusController.presentation.statusItemAssetName(
      hasActiveWork: appStore.sessionIndex.totalActiveWorkCount > 0,
      showsStateColorVariants: menuBarStateColorVariantsEnabled
    )
  }

  private var menuBarStatusItemHelpText: String {
    HarnessMonitorMenuBarSnapshot.statusItemHelpText(
      hasActiveWork: appStore.sessionIndex.totalActiveWorkCount > 0
    )
  }

  private var menuBarStatusItemAccessibilityLabel: String {
    HarnessMonitorMenuBarSnapshot.statusItemAccessibilityLabel(
      hasActiveWork: appStore.sessionIndex.totalActiveWorkCount > 0,
      pendingDecisionCount: appMenuBarStatusController.presentation.pendingDecisionCount
    )
  }

  private var menuBarExtraLabel: some View {
    Label(HarnessMonitorMenuBarSnapshot.statusItemTitle, image: menuBarStatusItemImageName)
      .help(menuBarStatusItemHelpText)
      .accessibilityLabel(menuBarStatusItemAccessibilityLabel)
  }
}
