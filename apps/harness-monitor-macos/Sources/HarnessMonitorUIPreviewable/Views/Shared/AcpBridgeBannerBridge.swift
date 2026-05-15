import HarnessMonitorKit
import SwiftUI

struct AcpBridgeBannerBridge: View {
  let store: HarnessMonitorStore
  let contentChrome: HarnessMonitorStore.ContentChromeSlice
  let keyWindowObserver: KeyWindowObserver?
  let windowID: String
  @Environment(\.windowSurfaceContext)
  private var windowSurfaceContext
  @State private var lastAnnouncedIncidentAt: Date?

  private var bannerState: AcpBridgeBannerState? {
    contentChrome.acpBridgeBanner
  }

  private var shouldAnnounceBanner: Bool {
    guard bannerState != nil else {
      return false
    }
    if HarnessMonitorUITestEnvironment.isEnabled {
      return true
    }
    guard let keyWindowObserver else {
      return windowSurfaceContext.isKeyWindow
    }
    let snapshot = keyWindowObserver.snapshot
    guard !snapshot.prefersUserNotificationDelivery else {
      return false
    }
    return keyWindowObserver.isKey(windowID: effectiveWindowID)
  }

  private var effectiveWindowID: String {
    windowID.isEmpty ? windowSurfaceContext.windowID : windowID
  }

  private var visibleBannerAnnouncement: AcpBridgeBannerAnnouncement? {
    AcpBridgeBannerAnnouncement(
      state: bannerState,
      isVisible: shouldAnnounceBanner
    )
  }

  private func announceVisibleBannerIfNeeded(
    _ announcement: AcpBridgeBannerAnnouncement? = nil
  ) {
    let announcement = announcement ?? visibleBannerAnnouncement
    guard let announcement else {
      return
    }
    guard
      AcpBridgeBannerAnnouncement.shouldAnnounce(
        announcement,
        lastAnnouncedIncidentAt: lastAnnouncedIncidentAt
      )
    else {
      return
    }
    AccessibilityNotification.Announcement(announcement.message).post()
    lastAnnouncedIncidentAt = announcement.incidentID
  }

  var body: some View {
    Group {
      if let bannerState {
        AcpBridgeBanner(
          store: store,
          state: bannerState
        )
        .onAppear {
          announceVisibleBannerIfNeeded()
        }
      }
    }
    .onChange(of: visibleBannerAnnouncement) { _, newValue in
      announceVisibleBannerIfNeeded(newValue)
    }
  }
}

@MainActor
struct AcpBridgeBannerAnnouncement: Equatable {
  let incidentID: Date
  let message: String

  init?(state: AcpBridgeBannerState?, isVisible: Bool) {
    guard isVisible, let state else {
      return nil
    }
    incidentID = state.firstDetectedAt
    message = "ACP bridge outage. \(state.factText). \(AcpBridgeBannerState.blastRadiusText)."
  }

  static func shouldAnnounce(
    _ announcement: Self?,
    lastAnnouncedIncidentAt: Date?
  ) -> Bool {
    guard let announcement else {
      return false
    }
    return announcement.incidentID != lastAnnouncedIncidentAt
  }
}

private struct AcpBridgeBanner: View {
  let store: HarnessMonitorStore
  let state: AcpBridgeBannerState

  var body: some View {
    HStack(alignment: .top, spacing: HarnessMonitorTheme.spacingMD) {
      Image(systemName: "exclamationmark.triangle.fill")
        .font(.system(size: 15, weight: .semibold))
        .foregroundStyle(HarnessMonitorTheme.caution)
        .padding(.top, 2)
        .accessibilityHidden(true)

      VStack(alignment: .leading, spacing: HarnessMonitorTheme.itemSpacing) {
        Text(state.factText)
          .scaledFont(.caption.weight(.semibold))
          .foregroundStyle(.primary)
        Text(AcpBridgeBannerState.blastRadiusText)
          .scaledFont(.caption)
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
            _ = store.openDaemonLog()
          }
          .disabled(!state.daemonLogAvailable)

          HarnessMonitorAsyncActionButton(
            title: "Run doctor",
            tint: nil,
            variant: .prominent,
            isLoading: store.isDiagnosticsRefreshInFlight,
            accessibilityIdentifier: HarnessMonitorAccessibility.contentAcpBridgeRunDoctorButton
          ) {
            await store.runAcpBridgeDoctor()
          }
        }
      }

      Spacer(minLength: HarnessMonitorTheme.spacingLG)
    }
    .padding(.horizontal, HarnessMonitorTheme.spacingMD)
    .padding(.vertical, HarnessMonitorTheme.spacingSM)
    .frame(maxWidth: .infinity, alignment: .leading)
    .modifier(ChromeBannerSurfaceModifier(tint: HarnessMonitorTheme.caution))
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier(HarnessMonitorAccessibility.contentAcpBridgeBanner)
  }
}
