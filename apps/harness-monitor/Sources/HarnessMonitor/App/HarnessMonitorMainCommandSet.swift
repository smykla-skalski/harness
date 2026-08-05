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
  let presentOpenAnything: () -> Void
  let openAnythingCorpusSize: () -> Int

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
    OpenAnythingMenuCommands(
      presentOpenAnything: presentOpenAnything,
      openAnythingCorpusSize: openAnythingCorpusSize
    )
    OpenFolderCommand(store: store)
    AttachExternalSessionCommand(store: store)
    GoCommands(
      store: store,
      displayState: store.commandsDisplayState
    )
    ReviewCommands()
    HarnessMonitorSupplementalCommandSet()
  }
}

private struct HarnessMonitorSupplementalCommandSet: Commands {
  var body: some Commands {
    WindowMenuCommands()
    InspectorCommands()
    AuditTimelineCommand()
  }
}
