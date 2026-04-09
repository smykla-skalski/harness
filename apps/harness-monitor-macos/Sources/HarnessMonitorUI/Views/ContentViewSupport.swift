import HarnessMonitorKit
import Observation
import SwiftUI

public struct CommandsDisplayState: Equatable {
  public let canNavigateBack: Bool
  public let canNavigateForward: Bool
  public let hasSelectedSession: Bool
  public let isSessionReadOnly: Bool
  public let bookmarkTitle: String
  public let isPersistenceAvailable: Bool
  public let hasObserver: Bool
}

enum HarnessMonitorInspectorLayout {
  static let minWidth: CGFloat = 320
  static let idealWidth: CGFloat = 420
  static let maxWidth: CGFloat = 760
}

// MARK: - Toolbar store extensions

extension HarnessMonitorStore {
  // Keep Commands state as plain data. The scene-level FocusedValue bridge
  // emitted duplicate update faults during startup when the window toolbar
  // and command menu refreshed in the same frame.
  public var commandsDisplayState: CommandsDisplayState {
    CommandsDisplayState(
      canNavigateBack: canNavigateBack,
      canNavigateForward: canNavigateForward,
      hasSelectedSession: selectedSessionID != nil,
      isSessionReadOnly: isSessionReadOnly,
      bookmarkTitle: selectedSessionBookmarkTitle,
      isPersistenceAvailable: isPersistenceAvailable,
      hasObserver: selectedSession?.observer != nil
    )
  }

  var toolbarCenterpieceModel: ToolbarCenterpieceModel {
    ToolbarCenterpieceModel(
      workspaceName: "Harness Monitor",
      destinationName: "My Mac",
      destinationSystemImage: "laptopcomputer",
      metrics: [
        .init(kind: .projects, value: projects.count),
        .init(
          kind: .worktrees,
          value: groupedSessions.reduce(0) { $0 + $1.checkoutGroups.count }
        ),
        .init(kind: .sessions, value: sessions.count),
        .init(kind: .openWork, value: totalOpenWorkCount),
        .init(kind: .blocked, value: totalBlockedCount),
      ]
    )
  }

  var toolbarStatusMessages: [ToolbarStatusMessage] {
    var messages: [ToolbarStatusMessage] = []

    if !lastAction.isEmpty {
      messages.append(
        ToolbarStatusMessage(
          id: "last-action",
          text: lastAction,
          systemImage: "checkmark.circle.fill",
          tint: .green
        )
      )
    }

    switch connectionState {
    case .connecting:
      messages.append(
        ToolbarStatusMessage(
          id: "connecting",
          text: "Connecting to daemon",
          systemImage: "arrow.trianglehead.2.clockwise",
          tint: .orange
        )
      )
    case .offline(let reason):
      messages.append(
        ToolbarStatusMessage(
          id: "offline",
          text: isShowingCachedData || persistedSessionCount > 0 || !sessions.isEmpty
            ? cachedDataStatusMessage
            : reason,
          systemImage: "wifi.slash",
          tint: .secondary
        )
      )
    case .online:
      if isRefreshing {
        messages.append(
          ToolbarStatusMessage(
            id: "refreshing",
            text: "Refreshing sessions",
            systemImage: "arrow.clockwise",
            tint: .secondary
          )
        )
      }
    case .idle:
      break
    }

    return messages
  }

  var toolbarDaemonIndicator: ToolbarDaemonIndicator {
    guard connectionState == .online else {
      return .offline
    }
    if daemonStatus?.launchAgent.installed == true {
      return .launchdConnected
    }
    return .manualConnected
  }
}

// MARK: - Sidebar search controller

@MainActor
@Observable
public final class SidebarSearchController {
  public var focusRequestToken = 0

  public init() {}

  public func requestFocus() {
    focusRequestToken &+= 1
  }
}

// MARK: - Content toolbar items

struct ContentNavigationToolbarItems: ToolbarContent {
  let store: HarnessMonitorStore
  let navigateBack: () -> Void
  let navigateForward: () -> Void

  var body: some ToolbarContent {
    ContentNavigationToolbar(
      canNavigateBack: store.canNavigateBack,
      canNavigateForward: store.canNavigateForward,
      navigateBack: navigateBack,
      navigateForward: navigateForward
    )
  }
}

struct ContentCenterpieceToolbarItems: ToolbarContent {
  let store: HarnessMonitorStore
  let displayMode: ToolbarCenterpieceDisplayMode
  let availableDetailWidth: CGFloat
  @Binding var showLlama: Bool
  let toggleSleepPrevention: () -> Void

  var body: some ToolbarContent {
    ContentCenterpieceToolbar(
      model: store.toolbarCenterpieceModel,
      displayMode: displayMode,
      availableDetailWidth: availableDetailWidth,
      statusMessages: store.toolbarStatusMessages,
      daemonIndicator: store.toolbarDaemonIndicator
    )

    ToolbarItemGroup(placement: .principal) {
      Button(action: toggleSleepPrevention) {
        Label(
          store.sleepPreventionEnabled ? "Sleep Prevention On" : "Prevent Sleep",
          systemImage: store.sleepPreventionEnabled ? "moon.zzz.fill" : "moon.zzz"
        )
      }
      .tint(store.sleepPreventionEnabled ? .orange : nil)
      .help(
        store.sleepPreventionEnabled
          ? "Preventing sleep - click to disable"
          : "Allow sleep - click to prevent"
      )
      .accessibilityIdentifier(HarnessMonitorAccessibility.sleepPreventionButton)

      Button { showLlama.toggle() } label: {
        Label(
          showLlama ? "Hide Llama" : "Show Llama",
          systemImage: showLlama ? "hare.fill" : "hare"
        )
      }
      .tint(showLlama ? .purple : nil)
      .help(showLlama ? "Hide dancing llama" : "Show dancing llama")
    }
    .sharedBackgroundVisibility(.hidden)
  }
}

struct ContentPrimaryToolbarItems: ToolbarContent {
  @Bindable var contentUI: HarnessMonitorStore.ContentUISlice
  @Binding var showInspector: Bool
  let openPreferences: () -> Void
  let refresh: () -> Void

  init(
    contentUI: HarnessMonitorStore.ContentUISlice,
    showInspector: Binding<Bool>,
    openPreferences: @escaping () -> Void,
    refresh: @escaping () -> Void
  ) {
    self.contentUI = contentUI
    self._showInspector = showInspector
    self.openPreferences = openPreferences
    self.refresh = refresh
  }

  var body: some ToolbarContent {
    InspectorToolbarActions(
      contentUI: contentUI,
      showInspector: $showInspector,
      openPreferences: openPreferences,
      refresh: refresh
    )
  }
}

struct ContentToolbarAccessibilityMarker: View {
  let store: HarnessMonitorStore

  var body: some View {
    AccessibilityTextMarker(
      identifier: HarnessMonitorAccessibility.toolbarCenterpieceState,
      text: store.toolbarCenterpieceModel.accessibilityValue
    )
  }
}
