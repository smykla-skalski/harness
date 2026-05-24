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
  let presentOpenAnythingSessions: () -> Void
  let openAnythingCorpusSize: () -> Int

  var body: some Commands {
    // `NewSessionCommand` contributes `CommandGroup(replacing: .newItem)` -
    // any sibling `CommandGroup(after: .newItem)` placed BEFORE it in this
    // result-builder body is silently dropped by macOS. Keep the replacing
    // group first so every `(after: .newItem)` sibling below actually
    // renders (Open Anything + the New Task / Send Signal pair were both
    // lost by being authored before this line).
    NewSessionCommand(
      store: store,
      keyWindowObserver: keyWindowObserver,
      windowCommandRouting: windowCommandRouting
    )
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
      presentOpenAnythingSessions: presentOpenAnythingSessions,
      openAnythingCorpusSize: openAnythingCorpusSize
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
