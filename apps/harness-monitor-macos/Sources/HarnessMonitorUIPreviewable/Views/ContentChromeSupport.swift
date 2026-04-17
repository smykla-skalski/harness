import HarnessMonitorKit
import SwiftUI

public struct HarnessMonitorConfirmationDialogModifier: ViewModifier {
  public let store: HarnessMonitorStore
  public let shellUI: HarnessMonitorStore.ContentShellSlice

  public init(store: HarnessMonitorStore, shellUI: HarnessMonitorStore.ContentShellSlice) {
    self.store = store
    self.shellUI = shellUI
  }

  public func body(content: Content) -> some View {
    content
      .confirmationDialog(
        title,
        isPresented: Binding(
          get: { shellUI.pendingConfirmation != nil },
          set: { isPresented in
            if !isPresented {
              store.cancelConfirmation()
            }
          }
        ),
        titleVisibility: .visible
      ) {
        switch shellUI.pendingConfirmation {
        case .endSession(_, let actorID):
          Button("End Session Now", role: .destructive) {
            Task { await store.endSelectedSession(actor: actorID) }
          }
        case .removeAgent(_, let agentID, let actorID):
          Button("Remove Agent Now", role: .destructive) {
            Task { await store.removeAgent(agentID: agentID, actor: actorID) }
          }
        case nil:
          EmptyView()
        }
        Button("Cancel", role: .cancel) {
          store.cancelConfirmation()
        }
      } message: {
        if !message.isEmpty {
          Text(message)
        }
      }
  }

  private var title: String {
    switch shellUI.pendingConfirmation {
    case .endSession: "End Session?"
    case .removeAgent: "Remove Agent?"
    case nil: ""
    }
  }

  private var message: String {
    switch shellUI.pendingConfirmation {
    case .endSession(let sessionID, let actorID):
      "This ends \(sessionID) using \(actorID). Active task work must already be closed."
    case .removeAgent(_, let agentID, let actorID):
      "This removes \(agentID) using \(actorID) and returns any active work to the queue."
    case nil:
      ""
    }
  }
}

struct ContentDetailChrome<Content: View>: View {
  let persistenceError: String?
  let sessionDataAvailability: HarnessMonitorStore.SessionDataAvailability
  @ViewBuilder let content: Content

  var body: some View {
    contentWithTopChrome
      .frame(maxWidth: .infinity, maxHeight: .infinity)
  }

  @ViewBuilder private var contentWithTopChrome: some View {
    if showsTopChrome {
      content
        .safeAreaInset(edge: .top, spacing: 0) {
          topChrome
        }
    } else {
      content
    }
  }

  private var showsTopChrome: Bool {
    persistenceError != nil
      || sessionDataAvailability != .live
  }

  private var isStale: Bool {
    sessionDataAvailability != .live
  }

  private var topChrome: some View {
    VStack(spacing: 0) {
      if let persistenceError {
        PersistenceUnavailableBanner(message: persistenceError)
        chromeDivider(tint: HarnessMonitorTheme.caution)
      }
      if isStale {
        SessionDataAvailabilityBanner(availability: sessionDataAvailability)
        chromeDivider(tint: HarnessMonitorTheme.caution)
      }
    }
    .background(Color(nsColor: .windowBackgroundColor))
  }

  private func chromeDivider(tint: Color) -> some View {
    Rectangle()
      .fill(tint.opacity(0.35))
      .frame(height: 1)
      .accessibilityHidden(true)
  }
}

private enum SessionStatusCornerLayout {
  static let leadingInset: CGFloat = 24
  static let trailingBleed: CGFloat = 240
  static let topInset: CGFloat = HarnessMonitorTheme.spacingMD
  static let bottomBleed: CGFloat = 200
}

private struct SessionStatusCornerLabelRow: View {
  let status: SessionStatus
  let isStale: Bool

  var body: some View {
    HStack(alignment: .center, spacing: HarnessMonitorTheme.itemSpacing) {
      if isStale {
        Image(systemName: "clock.badge.questionmark")
          .font(.system(size: 9, weight: .bold))
          .accessibilityHidden(true)
      }
      Text(status.title.uppercased())
        .font(.system(size: 10, weight: .bold))
        .tracking(HarnessMonitorTheme.uppercaseTracking)
    }
  }
}

private struct SessionStatusCornerBounds: View {
  let status: SessionStatus
  let isStale: Bool

  var body: some View {
    SessionStatusCornerLabelRow(status: status, isStale: isStale)
      .hidden()
      .accessibilityHidden(true)
      .padding(.leading, SessionStatusCornerLayout.leadingInset)
      .padding(.trailing, SessionStatusCornerLayout.trailingBleed)
      .padding(.top, SessionStatusCornerLayout.topInset)
      .padding(.bottom, SessionStatusCornerLayout.bottomBleed)
  }
}

public struct SessionStatusCornerBackdrop: View {
  let status: SessionStatus
  let isStale: Bool

  @Environment(\.accessibilityReduceTransparency)
  private var reduceTransparency
  @Environment(\.colorSchemeContrast)
  private var colorSchemeContrast

  private var color: Color {
    isStale ? HarnessMonitorTheme.ink.opacity(0.55) : statusColor(for: status)
  }

  private var tintOpacity: Double {
    colorSchemeContrast == .increased ? 0.28 : 0.22
  }

  private var tintGradient: some View {
    LinearGradient(
      colors: [
        color.opacity(tintOpacity),
        color.opacity(0),
      ],
      startPoint: .topLeading,
      endPoint: .bottomTrailing
    )
  }

  private var backdropMask: some View {
    RadialGradient(
      stops: [
        .init(color: .black, location: 0),
        .init(color: .black.opacity(0.6), location: 0.4),
        .init(color: .clear, location: 0.75),
      ],
      center: .topLeading,
      startRadius: 0,
      endRadius: 320
    )
  }

  private var statusBackdrop: some View {
    Rectangle()
      .fill(Color(nsColor: .windowBackgroundColor).opacity(reduceTransparency ? 0.94 : 0.82))
      .overlay { tintGradient }
      .mask { backdropMask }
  }

  public init(status: SessionStatus, isStale: Bool) {
    self.status = status
    self.isStale = isStale
  }

  public var body: some View {
    SessionStatusCornerBounds(status: status, isStale: isStale)
      .background {
        statusBackdrop
      }
      .allowsHitTesting(false)
      .accessibilityHidden(true)
  }
}

struct SessionStatusCornerOverlay: View {
  let status: SessionStatus
  let isStale: Bool

  @Environment(\.colorSchemeContrast)
  private var colorSchemeContrast

  private var labelColor: Color {
    let baseColor = statusColor(for: status)
    let opacity = colorSchemeContrast == .increased ? 0.94 : 0.82
    return baseColor.opacity(opacity)
  }

  var body: some View {
    SessionStatusCornerBounds(status: status, isStale: isStale)
      .overlay(alignment: .topLeading) {
        SessionStatusCornerLabelRow(status: status, isStale: isStale)
          .foregroundStyle(labelColor)
          .padding(.leading, SessionStatusCornerLayout.leadingInset)
          .padding(.top, SessionStatusCornerLayout.topInset)
      }
      .allowsHitTesting(false)
      .accessibilityElement(children: .ignore)
      .accessibilityLabel("Session status")
      .accessibilityValue(isStale ? "\(status.title), estimated" : status.title)
      .accessibilityIdentifier(HarnessMonitorAccessibility.sessionStatusCorner)
      .accessibilityFrameMarker(HarnessMonitorAccessibility.sessionStatusCornerFrame)
  }
}

private struct ChromeBannerSurfaceModifier: ViewModifier {
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

public struct ContentAnnouncementsModifier: ViewModifier {
  public let shellUI: HarnessMonitorStore.ContentShellSlice

  public init(shellUI: HarnessMonitorStore.ContentShellSlice) {
    self.shellUI = shellUI
  }

  public func body(content: Content) -> some View {
    content
      .onChange(of: shellUI.connectionState) { _, newState in
        guard let message = message(for: newState) else { return }
        AccessibilityNotification.Announcement(message).post()
      }
  }

  private func message(for state: HarnessMonitorStore.ConnectionState) -> String? {
    switch state {
    case .online:
      "Connected to daemon"
    case .connecting:
      "Connecting to daemon"
    case .offline(let reason):
      "Disconnected: \(reason)"
    case .idle:
      nil
    }
  }
}
