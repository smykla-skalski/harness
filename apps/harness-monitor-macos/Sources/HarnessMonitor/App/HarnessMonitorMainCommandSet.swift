import HarnessMonitorKit
import HarnessMonitorUIPreviewable
import SwiftUI

struct HarnessMonitorMainCommandSet: Commands {
  let store: HarnessMonitorStore
  let keyWindowObserver: KeyWindowObserver
  let windowCommandRouting: WindowCommandRoutingState
  let textSizeIndex: Int
  let increaseTextSize: () -> Void
  let decreaseTextSize: () -> Void
  let resetTextSize: () -> Void
  let refreshStore: () -> Void
  let presentOpenAnything: () -> Void

  var body: some Commands {
    HarnessMonitorAppCommands(
      store: store,
      displayState: store.commandsDisplayState,
      textSizeIndex: textSizeIndex,
      increaseTextSize: increaseTextSize,
      decreaseTextSize: decreaseTextSize,
      resetTextSize: resetTextSize,
      refreshStore: refreshStore,
      presentOpenAnything: presentOpenAnything
    )
    NewSessionCommand(
      store: store,
      keyWindowObserver: keyWindowObserver,
      windowCommandRouting: windowCommandRouting
    )
    SessionCreateCommands(
      store: store,
      windowCommandRouting: windowCommandRouting
    )
    OpenFolderCommand(store: store)
    RecentSessionsCommand(store: store)
    AttachExternalSessionCommand(store: store)
    GoCommands(
      store: store,
      displayState: store.commandsDisplayState
    )
    ReviewCommands()
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
    AuditTimelineCommand()
  }
}
