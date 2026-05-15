import HarnessMonitorKit

public struct CommandsDisplayState: Equatable {
  public let canNavigateBack: Bool
  public let canNavigateForward: Bool
  public let hasSelectedSession: Bool
  public let isSessionReadOnly: Bool
  public let bookmarkTitle: String
  public let isPersistenceAvailable: Bool
  public let hasObserver: Bool
}

extension HarnessMonitorStore {
  // Keep Commands state as plain data. Startup command enablement now reads a
  // tracked key-window scope plus these snapshots instead of scene FocusedValue
  // propagation, which avoided same-frame update faults during launch.
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
