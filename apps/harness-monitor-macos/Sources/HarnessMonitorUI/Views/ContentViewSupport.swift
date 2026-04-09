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

// MARK: - Commands state

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
}

private extension HarnessMonitorStore.ContentUISlice {
  var toolbarCenterpieceModel: ToolbarCenterpieceModel {
    var metrics: [ToolbarCenterpieceMetric] = [
      .init(kind: .projects, value: toolbarMetrics.projectCount),
      .init(kind: .sessions, value: toolbarMetrics.sessionCount),
      .init(kind: .openWork, value: toolbarMetrics.openWorkCount),
      .init(kind: .blocked, value: toolbarMetrics.blockedCount),
    ]
    if toolbarMetrics.worktreeCount > 0 {
      metrics.insert(.init(kind: .worktrees, value: toolbarMetrics.worktreeCount), at: 1)
    }

    return ToolbarCenterpieceModel(
      workspaceName: "Harness Monitor",
      destinationName: "My Mac",
      destinationSystemImage: "laptopcomputer",
      metrics: metrics
    )
  }

  var toolbarStatusMessages: [ToolbarStatusMessage] {
    statusMessages.map(ToolbarStatusMessage.init)
  }

  var toolbarDaemonIndicator: ToolbarDaemonIndicator {
    ToolbarDaemonIndicator(daemonIndicator)
  }
}

// MARK: - Content toolbar items

struct ContentNavigationToolbarItems: ToolbarContent {
  @Bindable var contentUI: HarnessMonitorStore.ContentUISlice
  let navigateBack: () -> Void
  let navigateForward: () -> Void

  var body: some ToolbarContent {
    ContentNavigationToolbar(
      canNavigateBack: contentUI.canNavigateBack,
      canNavigateForward: contentUI.canNavigateForward,
      navigateBack: navigateBack,
      navigateForward: navigateForward
    )
  }
}

struct ContentCenterpieceToolbarItems: ToolbarContent {
  @Bindable var contentUI: HarnessMonitorStore.ContentUISlice
  let displayMode: ToolbarCenterpieceDisplayMode
  let availableDetailWidth: CGFloat
  let showsLlamaToggle: Bool
  @Binding var showLlama: Bool
  let toggleSleepPrevention: () -> Void

  var body: some ToolbarContent {
    ContentCenterpieceToolbar(
      model: contentUI.toolbarCenterpieceModel,
      displayMode: displayMode,
      availableDetailWidth: availableDetailWidth,
      statusMessages: contentUI.toolbarStatusMessages,
      daemonIndicator: contentUI.toolbarDaemonIndicator
    )

    ToolbarItemGroup(placement: .principal) {
      Button(action: toggleSleepPrevention) {
        Label(
          contentUI.sleepPreventionEnabled ? "Sleep Prevention On" : "Prevent Sleep",
          systemImage: contentUI.sleepPreventionEnabled ? "moon.zzz.fill" : "moon.zzz"
        )
      }
      .tint(contentUI.sleepPreventionEnabled ? .orange : nil)
      .help(
        contentUI.sleepPreventionEnabled
          ? "Preventing sleep - click to disable"
          : "Allow sleep - click to prevent"
      )
      .accessibilityIdentifier(HarnessMonitorAccessibility.sleepPreventionButton)

      if showsLlamaToggle {
        Button { showLlama.toggle() } label: {
          Label(
            showLlama ? "Hide Llama" : "Show Llama",
            systemImage: showLlama ? "hare.fill" : "hare"
          )
        }
        .tint(showLlama ? .purple : nil)
        .help(showLlama ? "Hide dancing llama" : "Show dancing llama")
      }
    }
    .sharedBackgroundVisibility(.hidden)
  }
}

struct ContentPrimaryToolbarItems: ToolbarContent {
  let store: HarnessMonitorStore
  @Bindable var contentUI: HarnessMonitorStore.ContentUISlice
  @Binding var showInspector: Bool

  var body: some ToolbarContent {
    InspectorToolbarActions(
      store: store,
      contentUI: contentUI,
      showInspector: $showInspector
    )
  }
}

struct ContentToolbarAccessibilityMarker: View {
  let contentUI: HarnessMonitorStore.ContentUISlice

  var body: some View {
    AccessibilityTextMarker(
      identifier: HarnessMonitorAccessibility.toolbarCenterpieceState,
      text: contentUI.toolbarCenterpieceModel.accessibilityValue
    )
  }
}
