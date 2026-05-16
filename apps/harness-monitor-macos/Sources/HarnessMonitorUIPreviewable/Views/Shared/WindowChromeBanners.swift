import HarnessMonitorKit
import SwiftUI

struct ChromeBannerSurfaceModifier: ViewModifier {
  let tint: Color
  @Environment(\.colorSchemeContrast)
  private var colorSchemeContrast

  private var tintOpacity: Double {
    colorSchemeContrast == .increased ? 0.18 : 0.14
  }

  func body(content: Content) -> some View {
    content.background {
      Color(nsColor: .windowBackgroundColor)
        .overlay(tint.opacity(tintOpacity))
    }
  }
}

struct ContentChromeBannerModel: Equatable {
  let showsPersistenceError: Bool
  let showsStaleData: Bool
  let showsMCPStatus: Bool
  let showsACPBridge: Bool

  init(
    persistenceError: String?,
    sessionDataAvailability: HarnessMonitorStore.SessionDataAvailability,
    mcpStatus: HarnessMonitorMCPStatusSnapshot,
    hasACPBridgeBanner: Bool
  ) {
    showsPersistenceError = persistenceError != nil
    showsStaleData = sessionDataAvailability != .live
    showsMCPStatus = mcpStatus.shouldShowChromeBanner
    showsACPBridge = hasACPBridgeBanner
  }

  var isPresented: Bool {
    showsPersistenceError || showsStaleData || showsMCPStatus || showsACPBridge
  }
}

struct ContentChromeBannerStack: View {
  let store: HarnessMonitorStore
  let contentChrome: HarnessMonitorStore.ContentChromeSlice
  let windowID: String

  var body: some View {
    VStack(spacing: 0) {
      if let persistenceError = contentChrome.persistenceError {
        PersistenceUnavailableBanner(message: persistenceError)
        chromeDivider(tint: HarnessMonitorTheme.caution)
      }
      if contentChrome.sessionDataAvailability != .live {
        SessionDataAvailabilityBanner(availability: contentChrome.sessionDataAvailability)
        chromeDivider(tint: HarnessMonitorTheme.caution)
      }
      if contentChrome.mcpStatus.shouldShowChromeBanner {
        MCPStatusBanner(status: contentChrome.mcpStatus)
        chromeDivider(tint: MCPStatusViewSupport.tint(for: contentChrome.mcpStatus.tone))
      }
      if contentChrome.acpBridgeBanner != nil {
        AcpBridgeBannerBridge(
          store: store,
          contentChrome: contentChrome,
          keyWindowObserver: nil,
          windowID: windowID
        )
        chromeDivider(tint: HarnessMonitorTheme.caution)
      }
    }
  }

  private func chromeDivider(tint: Color) -> some View {
    WindowBannerDivider(tint: tint)
  }
}

struct SessionDataAvailabilityBanner: View {
  let availability: HarnessMonitorStore.SessionDataAvailability

  var body: some View {
    HStack(alignment: .center, spacing: HarnessMonitorTheme.itemSpacing) {
      Image(systemName: symbolName)
        .scaledFont(.caption)
        .accessibilityHidden(true)
      Text(message)
        .scaledFont(.caption.weight(.medium))
      Spacer(minLength: 0)
    }
    .padding(.horizontal, HarnessMonitorTheme.spacingMD)
    .padding(.vertical, HarnessMonitorTheme.spacingSM)
    .foregroundStyle(HarnessMonitorTheme.caution)
    .modifier(ChromeBannerSurfaceModifier(tint: HarnessMonitorTheme.caution))
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(Text(message))
    .accessibilityValue(Text(message))
    .accessibilityIdentifier(HarnessMonitorAccessibility.persistedDataBanner)
    .accessibilityFrameMarker(HarnessMonitorAccessibility.persistedDataBannerFrame)
  }

  private var symbolName: String {
    switch availability {
    case .live:
      return "externaldrive"
    case .persisted:
      return "externaldrive.badge.wifi"
    case .unavailable:
      return "externaldrive.badge.exclamationmark"
    }
  }

  private var message: String {
    switch availability {
    case .live:
      return ""
    case .persisted(let reason, _, let lastSnapshotAt):
      return baseMessage(for: reason) + savedMessageSuffix(lastSnapshotAt)
    case .unavailable(let reason):
      switch reason {
      case .daemonOffline:
        return "Daemon is off. No persisted session snapshot is available yet."
      case .liveDataUnavailable:
        return "Live session detail is unavailable and no persisted session snapshot is available."
      }
    }
  }

  private func baseMessage(
    for reason: HarnessMonitorStore.PersistedSessionReason
  ) -> String {
    switch reason {
    case .daemonOffline:
      return "Daemon is off. Visible sessions are persisted snapshots and may be stale."
    case .liveDataUnavailable:
      return "Showing persisted session data because live session detail is unavailable."
    }
  }

  private func savedMessageSuffix(_ lastSnapshotAt: Date?) -> String {
    guard let lastSnapshotAt else {
      return ""
    }
    return " Last saved \(lastSnapshotAt.formatted(date: .abbreviated, time: .shortened))."
  }
}

struct DaemonWireVersionSkewBanner: View {
  let observed: Int
  let expected: Int

  var body: some View {
    HStack(alignment: .center, spacing: HarnessMonitorTheme.itemSpacing) {
      Image(systemName: "exclamationmark.triangle.fill")
        .scaledFont(.caption)
        .accessibilityHidden(true)
      Text(message)
        .scaledFont(.caption.weight(.medium))
      Spacer(minLength: 0)
    }
    .padding(.horizontal, HarnessMonitorTheme.spacingMD)
    .padding(.vertical, HarnessMonitorTheme.spacingSM)
    .foregroundStyle(HarnessMonitorTheme.danger)
    .modifier(ChromeBannerSurfaceModifier(tint: HarnessMonitorTheme.danger))
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(Text(message))
    .accessibilityValue(Text(message))
    .accessibilityIdentifier(HarnessMonitorAccessibility.daemonWireVersionSkewBanner)
  }

  private var message: String {
    "Connected daemon speaks wire version \(observed); this build expects \(expected). "
      + "Some features will be unavailable until the daemon is upgraded."
  }
}

struct PersistenceUnavailableBanner: View {
  let message: String

  var body: some View {
    HStack(alignment: .center, spacing: HarnessMonitorTheme.itemSpacing) {
      Image(systemName: "externaldrive.badge.exclamationmark")
        .scaledFont(.caption)
        .accessibilityHidden(true)
      Text(message)
        .scaledFont(.caption.weight(.medium))
      Spacer(minLength: 0)
    }
    .padding(.horizontal, HarnessMonitorTheme.spacingMD)
    .padding(.vertical, HarnessMonitorTheme.spacingSM)
    .foregroundStyle(HarnessMonitorTheme.caution)
    .modifier(ChromeBannerSurfaceModifier(tint: HarnessMonitorTheme.caution))
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(Text(message))
    .accessibilityValue(Text(message))
    .accessibilityIdentifier(HarnessMonitorAccessibility.persistenceBanner)
  }
}
