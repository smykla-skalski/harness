import AppKit
import HarnessMonitorKit
import SwiftUI

struct ContentFloatingOverlay: View {
  let toast: ToastSlice
  let auditBuildBadgeState: AuditBuildDisplayState?

  private var showsContent: Bool {
    !toast.activeFeedback.isEmpty
      || auditBuildBadgeState?.showsVisibleBadge == true
  }

  var body: some View {
    Group {
      if showsContent {
        VStack(alignment: .trailing, spacing: HarnessMonitorTheme.spacingSM) {
          if !toast.activeFeedback.isEmpty {
            HarnessMonitorFeedbackToastView(toast: toast)
          }
          if let auditBuildBadgeState, auditBuildBadgeState.showsVisibleBadge {
            AuditBuildBadge(state: auditBuildBadgeState)
          }
        }
        .padding(.top, HarnessMonitorTheme.spacingSM)
        .padding(.trailing, HarnessMonitorTheme.spacingLG)
      }
    }
  }
}

struct ContentAcpBridgeBannerBridge: View {
  let store: HarnessMonitorStore
  let contentChrome: HarnessMonitorStore.ContentChromeSlice
  let keyWindowObserver: KeyWindowObserver?
  let windowID: String

  private var bannerState: AcpBridgeBannerState? {
    contentChrome.acpBridgeBanner
  }

  private var shouldShowBanner: Bool {
    guard bannerState != nil else {
      return false
    }
    guard let keyWindowObserver else {
      return true
    }
    let snapshot = keyWindowObserver.snapshot
    guard !snapshot.prefersUserNotificationDelivery else {
      return false
    }
    return keyWindowObserver.isKey(windowID: windowID)
  }

  var body: some View {
    Group {
      if shouldShowBanner, let bannerState {
        ContentAcpBridgeBanner(
          store: store,
          state: bannerState
        )
      }
    }
  }
}

private struct ContentAcpBridgeBanner: View {
  let store: HarnessMonitorStore
  let state: AcpBridgeBannerState

  var body: some View {
    VStack(spacing: 0) {
      HStack(alignment: .top, spacing: HarnessMonitorTheme.spacingMD) {
        Image(systemName: "exclamationmark.triangle.fill")
          .font(.system(size: 15, weight: .semibold))
          .foregroundStyle(HarnessMonitorTheme.caution)
          .padding(.top, 2)
          .accessibilityHidden(true)

        VStack(alignment: .leading, spacing: HarnessMonitorTheme.itemSpacing) {
          Text(state.factText)
            .scaledFont(.system(.body, design: .rounded, weight: .semibold))
            .foregroundStyle(.primary)
          Text(AcpBridgeBannerState.blastRadiusText)
            .scaledFont(.system(.callout, design: .rounded, weight: .regular))
            .foregroundStyle(.secondary)

          HarnessMonitorWrapLayout(
            spacing: HarnessMonitorTheme.itemSpacing,
            lineSpacing: HarnessMonitorTheme.itemSpacing
          ) {
            HarnessMonitorActionButton(
              title: "Open daemon log",
              tint: .secondary,
              variant: .bordered,
              accessibilityIdentifier: HarnessMonitorAccessibility.contentAcpBridgeOpenLogButton
            ) {
              _ = store.revealDaemonLogInFinder()
            }
            .disabled(!state.daemonLogAvailable)

            HarnessMonitorAsyncActionButton(
              title: "Run doctor",
              tint: nil,
              variant: .prominent,
              isLoading: store.isDiagnosticsRefreshInFlight,
              accessibilityIdentifier: HarnessMonitorAccessibility.contentAcpBridgeRunDoctorButton
            ) {
              await store.refreshDiagnostics()
            }
          }
        }

        Spacer(minLength: HarnessMonitorTheme.spacingLG)
      }
      .padding(.horizontal, HarnessMonitorTheme.spacingLG)
      .padding(.vertical, HarnessMonitorTheme.spacingSM)

      Rectangle()
        .fill(HarnessMonitorTheme.caution.opacity(0.35))
        .frame(height: 1)
        .accessibilityHidden(true)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(
      Color(nsColor: .windowBackgroundColor)
        .overlay(HarnessMonitorTheme.caution.opacity(0.08))
    )
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier(HarnessMonitorAccessibility.contentAcpBridgeBanner)
  }
}

struct ContentEscapeCommandBridge: View {
  let store: HarnessMonitorStore
  let toast: ToastSlice
  let contentSessionDetail: HarnessMonitorStore.ContentSessionDetailSlice

  private func handleEscapeKeyPress() -> KeyPress.Result {
    if let feedbackID = toast.activeFeedback.first?.id {
      toast.dismiss(id: feedbackID)
      return .handled
    }
    return .ignored
  }

  private func handleExitCommand() {
    if let feedbackID = toast.activeFeedback.first?.id {
      toast.dismiss(id: feedbackID)
    }
  }

  var body: some View {
    Color.clear
      .allowsHitTesting(false)
      .onKeyPress(.escape, action: handleEscapeKeyPress)
      .onExitCommand(perform: handleExitCommand)
  }
}

struct ContentAccessibilityOverlayBridge: View {
  let contentSession: HarnessMonitorStore.ContentSessionSlice
  let contentSessionDetail: HarnessMonitorStore.ContentSessionDetailSlice
  let appChromeAccessibilityValue: String
  let supervisorBadgeAccessibilityValue: String
  let toolbarBackgroundMarker: String
  let auditBuildAccessibilityValue: String?

  var body: some View {
    if HarnessMonitorUITestEnvironment.accessibilityMarkersEnabled {
      ZStack {
        if HarnessMonitorUITestEnvironment.generalMarkersEnabled {
          AccessibilityTextMarker(
            identifier: HarnessMonitorAccessibility.appChromeState,
            text: appChromeAccessibilityValue
          )
          AccessibilityTextMarker(
            identifier: HarnessMonitorAccessibility.supervisorBadgeState,
            text: supervisorBadgeAccessibilityValue
          )
          ContentToolbarChromeAccessibilityMarker(
            contentSession: contentSession,
            contentSessionDetail: contentSessionDetail,
            toolbarBackgroundMarker: toolbarBackgroundMarker
          )
        }
        if let auditBuildAccessibilityValue {
          AccessibilityTextMarker(
            identifier: HarnessMonitorAccessibility.auditBuildState,
            text: auditBuildAccessibilityValue
          )
        }
      }
    }
  }
}

struct ContentSceneRestorationBridge: View {
  let store: HarnessMonitorStore
  let selection: HarnessMonitorStore.SelectionSlice
  let availableSessionCount: Int
  let connectionState: HarnessMonitorStore.ConnectionState
  let onRestorationResolved: () -> Void
  @SceneStorage("selectedSessionID")
  private var restoredSessionID: String?
  @State private var hasResolvedSceneRestoration = false
  @State private var hasObservedConnectionAttempt = false
  @State private var hasRequestedSceneRestorationSelection = false

  var body: some View {
    Color.clear
      .allowsHitTesting(false)
      .onAppear {
        if connectionState != .idle {
          hasObservedConnectionAttempt = true
        }
        resolveRestorationIfNeeded(from: restoredSessionID)
      }
      .onChange(of: restoredSessionID) { _, newID in
        resolveRestorationIfNeeded(from: newID)
      }
      .onChange(of: selection.selectedSessionID) { _, newID in
        if restoredSessionID != newID {
          restoredSessionID = newID
        }
        if newID != nil {
          markRestorationResolved()
        }
      }
      .onChange(of: availableSessionCount) { _, _ in
        resolveRestorationIfNeeded(from: restoredSessionID)
      }
      .onChange(of: connectionState) { _, newState in
        if newState != .idle {
          hasObservedConnectionAttempt = true
        }
        resolveRestorationIfNeeded(from: restoredSessionID)
      }
  }

  private func resolveRestorationIfNeeded(from restoredSessionID: String?) {
    guard !hasResolvedSceneRestoration else {
      return
    }
    guard selection.selectedSessionID == nil else {
      markRestorationResolved()
      return
    }
    guard let restoredSessionID else {
      markRestorationResolved()
      return
    }

    if availableSessionCount > 0 {
      guard store.sessionIndex.sessionSummary(for: restoredSessionID) != nil else {
        self.restoredSessionID = nil
        markRestorationResolved()
        return
      }
      guard !hasRequestedSceneRestorationSelection else {
        return
      }
      hasRequestedSceneRestorationSelection = true
      store.selectSessionFromList(restoredSessionID)
      return
    }

    guard hasObservedConnectionAttempt, connectionState != .connecting else {
      return
    }
    self.restoredSessionID = nil
    markRestorationResolved()
  }

  private func markRestorationResolved() {
    guard !hasResolvedSceneRestoration else {
      return
    }
    hasResolvedSceneRestoration = true
    onRestorationResolved()
  }
}

private struct ContentToolbarChromeAccessibilityMarker: View {
  let contentSession: HarnessMonitorStore.ContentSessionSlice
  let contentSessionDetail: HarnessMonitorStore.ContentSessionDetailSlice
  let toolbarBackgroundMarker: String

  private var windowTitle: String {
    contentSessionDetail.presentedSessionDetail != nil ? "Cockpit" : "Dashboard"
  }

  var body: some View {
    AccessibilityTextMarker(
      identifier: HarnessMonitorAccessibility.toolbarChromeState,
      text: [
        "toolbarTitle=native-window",
        "windowTitle=\(windowTitle)",
        "toolbarBackground=\(toolbarBackgroundMarker)",
      ].joined(separator: ", ")
    )
  }
}
