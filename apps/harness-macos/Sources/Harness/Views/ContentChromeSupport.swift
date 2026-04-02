import HarnessKit
import Observation
import SwiftUI

struct InspectorVisibilityKey: FocusedValueKey {
  typealias Value = Binding<Bool>
}

extension FocusedValues {
  var inspectorVisibility: Binding<Bool>? {
    get { self[InspectorVisibilityKey.self] }
    set { self[InspectorVisibilityKey.self] = newValue }
  }
}

struct HarnessConfirmationDialogModifier: ViewModifier {
  @Bindable var store: HarnessStore

  func body(content: Content) -> some View {
    content
      .confirmationDialog(
        title,
        isPresented: $store.showConfirmation,
        titleVisibility: .visible
      ) {
        switch store.pendingConfirmation {
        case .endSession:
          Button("End Session Now", role: .destructive) {
            Task { await store.confirmPendingAction() }
          }
        case .removeAgent:
          Button("Remove Agent Now", role: .destructive) {
            Task { await store.confirmPendingAction() }
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
    switch store.pendingConfirmation {
    case .endSession: "End Session?"
    case .removeAgent: "Remove Agent?"
    case nil: ""
    }
  }

  private var message: String {
    switch store.pendingConfirmation {
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
  let sessionDataAvailability: HarnessStore.SessionDataAvailability
  @ViewBuilder let content: Content

  var body: some View {
    VStack(spacing: 0) {
      if let persistenceError {
        PersistenceUnavailableBanner(message: persistenceError)
      }
      if sessionDataAvailability != .live {
        SessionDataAvailabilityBanner(availability: sessionDataAvailability)
      }
      content
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
  }
}

enum ToolbarBaselineRegion: Hashable {
  case sidebar
}

private enum ToolbarBaselineCoordinateSpace {
  static let name = "harness.toolbar-baseline"
}

private struct ToolbarBaselineFramePreferenceKey: PreferenceKey {
  static let defaultValue: [ToolbarBaselineRegion: CGRect] = [:]

  static func reduce(
    value: inout [ToolbarBaselineRegion: CGRect],
    nextValue: () -> [ToolbarBaselineRegion: CGRect]
  ) {
    value.merge(nextValue(), uniquingKeysWith: { _, next in next })
  }
}

private struct ToolbarBaselineFrameModifier: ViewModifier {
  let region: ToolbarBaselineRegion

  func body(content: Content) -> some View {
    content.background {
      GeometryReader { proxy in
        Color.clear.preference(
          key: ToolbarBaselineFramePreferenceKey.self,
          value: [
            region: proxy.frame(in: .named(ToolbarBaselineCoordinateSpace.name))
          ]
        )
      }
    }
  }
}

private struct ToolbarBaselineOverlayModifier: ViewModifier {
  @State private var sidebarMaxX: CGFloat = 0

  func body(content: Content) -> some View {
    content
      .coordinateSpace(name: ToolbarBaselineCoordinateSpace.name)
      .onPreferenceChange(ToolbarBaselineFramePreferenceKey.self) { frames in
        sidebarMaxX = max(frames[.sidebar]?.maxX ?? 0, 0)
      }
      .overlay(alignment: .topLeading) {
        GeometryReader { proxy in
          let dividerWidth = max(proxy.size.width - sidebarMaxX, 0)

          if dividerWidth > 0 {
            ToolbarBaselineDivider()
              .frame(width: dividerWidth, alignment: .leading)
              .offset(x: sidebarMaxX)
          }
        }
        .allowsHitTesting(false)
      }
  }
}

private struct ToolbarBaselineDivider: View {
  var body: some View {
    Divider()
      .frame(height: 1)
      .accessibilityFrameMarker(HarnessAccessibility.toolbarBaselineDivider)
  }
}

struct SessionDataAvailabilityBanner: View {
  let availability: HarnessStore.SessionDataAvailability

  var body: some View {
    HStack(alignment: .top, spacing: HarnessTheme.itemSpacing) {
      Image(systemName: symbolName)
        .scaledFont(.caption)
        .accessibilityHidden(true)
      Text(message)
        .scaledFont(.caption.weight(.medium))
      Spacer(minLength: 0)
    }
    .harnessCellPadding()
    .background(HarnessTheme.caution.opacity(0.12))
    .foregroundStyle(HarnessTheme.caution)
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(Text(message))
    .accessibilityValue(Text(message))
    .accessibilityIdentifier(HarnessAccessibility.persistedDataBanner)
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
    for reason: HarnessStore.PersistedSessionReason
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
    HStack(alignment: .top, spacing: HarnessTheme.itemSpacing) {
      Image(systemName: "externaldrive.badge.exclamationmark")
        .scaledFont(.caption)
        .accessibilityHidden(true)
      Text(message)
        .scaledFont(.caption.weight(.medium))
      Spacer(minLength: 0)
    }
    .harnessCellPadding()
    .background(HarnessTheme.caution.opacity(0.18))
    .foregroundStyle(HarnessTheme.caution)
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(Text(message))
    .accessibilityValue(Text(message))
    .accessibilityIdentifier(HarnessAccessibility.persistenceBanner)
  }
}

struct ContentAnnouncementsModifier: ViewModifier {
  let connectionState: HarnessStore.ConnectionState
  let lastAction: String

  func body(content: Content) -> some View {
    content
      .onChange(of: connectionState) { _, newState in
        guard let message = message(for: newState) else { return }
        AccessibilityNotification.Announcement(message).post()
      }
      .onChange(of: lastAction) { _, action in
        guard !action.isEmpty else { return }
        AccessibilityNotification.Announcement(action).post()
      }
  }

  private func message(for state: HarnessStore.ConnectionState) -> String? {
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

struct ContentNavigationToolbar: ToolbarContent {
  let canNavigateBack: Bool
  let canNavigateForward: Bool
  let navigateBack: () -> Void
  let navigateForward: () -> Void

  var body: some ToolbarContent {
    ToolbarItemGroup(placement: .navigation) {
      Button(action: navigateBack) {
        Label("Back", systemImage: "chevron.backward")
      }
      .disabled(!canNavigateBack)
      .help("Go back")
      .accessibilityIdentifier(HarnessAccessibility.navigateBackButton)

      Button(action: navigateForward) {
        Label("Forward", systemImage: "chevron.forward")
      }
      .disabled(!canNavigateForward)
      .help("Go forward")
      .accessibilityIdentifier(HarnessAccessibility.navigateForwardButton)
    }
  }
}

struct RefreshToolbarButton: View {
  let isRefreshing: Bool
  let refresh: () -> Void
  @Environment(\.accessibilityReduceMotion)
  private var reduceMotion
  @State private var isSpinning = false

  var body: some View {
    Button(action: refresh) {
      Label {
        Text("Refresh")
      } icon: {
        Image(systemName: "arrow.clockwise")
          .rotationEffect(.degrees(reduceMotion ? 0 : (isSpinning ? 360 : 0)))
          .animation(
            reduceMotion
              ? nil
              : isSpinning
              ? .linear(duration: 0.9).repeatForever(autoreverses: false)
              : .easeOut(duration: 0.4),
            value: isSpinning
          )
      }
    }
    .accessibilityIdentifier(HarnessAccessibility.refreshButton)
    .onChange(of: isRefreshing) { _, refreshing in
      isSpinning = refreshing
    }
  }
}

extension View {
  func toolbarBaselineFrame(_ region: ToolbarBaselineRegion) -> some View {
    modifier(ToolbarBaselineFrameModifier(region: region))
  }

  func toolbarBaselineOverlay() -> some View {
    modifier(ToolbarBaselineOverlayModifier())
  }
}
