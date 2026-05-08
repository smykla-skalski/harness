import HarnessMonitorKit
import HarnessMonitorUIPreviewable
import SwiftUI

struct HarnessMonitorMainCommandSet: Commands {
  let store: HarnessMonitorStore
  let textSizeIndex: Int
  let increaseTextSize: () -> Void
  let decreaseTextSize: () -> Void
  let resetTextSize: () -> Void
  let refreshStore: () -> Void

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
    NewSessionCommand(store: store)
    SessionCreateCommands()
    OpenFolderCommand(store: store)
    AttachExternalSessionCommand(store: store)
    GoCommands(
      store: store,
      displayState: store.commandsDisplayState
    )
    SessionCommands(
      store: store,
      displayState: store.commandsDisplayState
    )
    WindowMenuCommands(
      store: store
    )
    InspectorCommands()
    DecisionCommands()
  }
}
