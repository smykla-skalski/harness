import HarnessMonitorKit
import HarnessMonitorUIPreviewable
import SwiftUI

struct HarnessMonitorMainCommandSet: Commands {
  let store: HarnessMonitorStore
  let windowCommandRouting: WindowCommandRoutingState
  let textSizeIndex: Int
  let increaseTextSize: () -> Void
  let decreaseTextSize: () -> Void
  let resetTextSize: () -> Void
  let refreshStore: () -> Void
  @FocusedValue(\.sessionCreateContext)
  private var sessionCreate

  var body: some Commands {
    HarnessMonitorAppCommands(
      store: store,
      displayState: store.commandsDisplayState,
      textSizeIndex: textSizeIndex,
      increaseTextSize: increaseTextSize,
      decreaseTextSize: decreaseTextSize,
      resetTextSize: resetTextSize,
      refreshStore: refreshStore
    )
    NewSessionCommand(store: store, sessionCreate: sessionCreate)
    SessionCreateCommands(
      store: store,
      windowCommandRouting: windowCommandRouting,
      sessionCreate: sessionCreate
    )
    OpenFolderCommand(store: store)
    RecentSessionsCommand(store: store)
    AttachExternalSessionCommand(store: store)
    GoCommands(
      store: store,
      displayState: store.commandsDisplayState
    )
    HarnessMonitorSupplementalCommandSet(
      store: store,
      displayState: store.commandsDisplayState
    )
  }
}

private struct HarnessMonitorSupplementalCommandSet: Commands {
  let store: HarnessMonitorStore
  let displayState: CommandsDisplayState

  var body: some Commands {
    SessionCommands(
      store: store,
      displayState: displayState
    )
    WindowMenuCommands(
      store: store
    )
    SessionWindowCycleCommands()
    InspectorCommands()
    DecisionCommands()
  }
}
