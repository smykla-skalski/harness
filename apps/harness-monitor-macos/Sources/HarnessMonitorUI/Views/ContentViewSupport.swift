import HarnessMonitorKit
import Observation
import SwiftUI

// MARK: - Focused value for Commands

/// Window-scoped display state published to scene-level Commands via
/// `.focusedSceneValue()`. Commands reads this through `@FocusedValue`
/// instead of observing the store directly, so Commands and toolbar
/// content don't both push FocusedValue updates in the same frame.
public struct CommandsDisplayState: Equatable {
  public let canNavigateBack: Bool
  public let canNavigateForward: Bool
  public let hasSelectedSession: Bool
  public let isSessionReadOnly: Bool
  public let bookmarkTitle: String
  public let isPersistenceAvailable: Bool
  public let hasObserver: Bool
}

private struct CommandsDisplayStateKey: FocusedValueKey {
  typealias Value = CommandsDisplayState
}

public extension FocusedValues {
  var commandsDisplayState: CommandsDisplayState? {
    get { self[CommandsDisplayStateKey.self] }
    set { self[CommandsDisplayStateKey.self] = newValue }
  }
}

enum HarnessMonitorInspectorLayout {
  static let minWidth: CGFloat = 320
  static let idealWidth: CGFloat = 420
  static let maxWidth: CGFloat = 760
}

// MARK: - Toolbar store extensions

extension HarnessMonitorStore {
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

// MARK: - Commands display state publisher

/// Publishes Commands display state as a focused scene value from an
/// isolated background view. Keeping this separate from ContentView
/// prevents `.focusedSceneValue()` and `.toolbar()` from both writing
/// to the FocusedValue pipeline in the same body evaluation. This view
/// only re-evaluates when the specific store properties it reads change,
/// not when toolbar-related properties (metrics, status messages) change.
struct CommandsDisplayStatePublisher: View {
  let store: HarnessMonitorStore

  var body: some View {
    Color.clear
      .focusedSceneValue(\.commandsDisplayState, CommandsDisplayState(
        canNavigateBack: store.canNavigateBack,
        canNavigateForward: store.canNavigateForward,
        hasSelectedSession: store.selectedSessionID != nil,
        isSessionReadOnly: store.isSessionReadOnly,
        bookmarkTitle: store.selectedSessionBookmarkTitle,
        isPersistenceAvailable: store.isPersistenceAvailable,
        hasObserver: store.selectedSession?.observer != nil
      ))
      .allowsHitTesting(false)
      .accessibilityHidden(true)
  }
}
