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
      .harnessTrackMCPWindow()
      .environment(appStore)
      .dashboardDebuggingOCRPasteCommand()
      .dashboardReviewsTextPasteCommand()
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
        .dashboardReviewsTextPasteCommand()
        .onOpenURL { url in
          handleHarnessDeepLink(url)
        }
        .sheet(
          isPresented: Binding(
            get: { pendingPairingURLValue != nil },
            set: {
              if !$0 {
                pendingPairingURLValue = nil
                pendingPairingInvitationValue = nil
                pendingPairingErrorValue = nil
              }
            }
          )
        ) {
          pairingConfirmationSheetContent
        }
        .alert(
          "Invalid Pairing Link",
          isPresented: Binding(
            get: { pendingPairingErrorValue != nil },
            set: {
              if !$0 {
                pendingPairingErrorValue = nil
                pendingPairingURLValue = nil
                pendingPairingInvitationValue = nil
              }
            }
          )
        ) {
          // Dismissal runs the isPresented setter above, which clears the
          // pending pairing state; the button only needs to close the alert.
          Button("OK") {}
        } message: {
          if let error = pendingPairingErrorValue {
            Text(error.localizedDescription)
          }
        }
    } else {
      Color.clear.accessibilityHidden(true)
    }
  }

  /// Handles incoming `harness://` URLs. Remote-pairing links show a
  /// confirmation sheet before pairing. Other routes go through the deep-link
  /// router for review / task-board navigation.
  func handleHarnessDeepLink(_ url: URL) {
    if url.scheme?.lowercased() == "harness",
      url.host?.lowercased() == "remote-pair"
    {
      do {
        let invitation = try RemoteDaemonPairingInvitation.decode(url)
        pendingPairingInvitationValue = invitation
        pendingPairingURLValue = url
        pendingPairingErrorValue = nil
      } catch let error as RemoteDaemonPairingInvitationError {
        pendingPairingInvitationValue = nil
        pendingPairingURLValue = nil
        pendingPairingErrorValue = error
      } catch {
        pendingPairingInvitationValue = nil
        pendingPairingURLValue = nil
        pendingPairingErrorValue = .invalidPayload
      }
      return
    }
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

  @ViewBuilder
  private var pairingConfirmationSheetContent: some View {
    if let url = pendingPairingURLValue,
      let invitation = pendingPairingInvitationValue
    {
      RemoteDaemonPairingConfirmationView(
        invitation: invitation,
        onPair: { displayName in
          appStore.pairRemoteDaemon(
            using: .deepLink(url.absoluteString),
            displayName: displayName
          )
          settingsSelectedSectionBinding.wrappedValue = .connection
          openWindow(id: HarnessMonitorWindowID.settings)
          pendingPairingURLValue = nil
          pendingPairingInvitationValue = nil
        },
        onCancel: {
          pendingPairingURLValue = nil
          pendingPairingInvitationValue = nil
        }
      )
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
      .dashboardReviewsTextPasteCommand()
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
      refreshStore: refreshStore,
      settingsSelectedSection: settingsSelectedSectionBinding,
      settingsNavigationRequest: settingsNavigationRequestBinding,
      hasBound: hasBoundOpenAnythingExecutorBinding
    )
  }
}
