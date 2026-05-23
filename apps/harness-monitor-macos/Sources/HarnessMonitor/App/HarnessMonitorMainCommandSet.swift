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
    HarnessMonitorAppCommands(
      store: store,
      displayState: store.commandsDisplayState,
      textSizeIndex: textSizeIndex,
      increaseTextSize: increaseTextSize,
      decreaseTextSize: decreaseTextSize,
      resetTextSize: resetTextSize,
      refreshStore: refreshStore
    )
    // Lifted out of `HarnessMonitorAppCommands.fileAndEditCommands` because a
    // single Commands struct cannot reliably contribute multiple
    // `CommandGroup(after: .newItem)` blocks - macOS only renders one and
    // silently drops the rest. As a sibling here it composes with the other
    // file-menu contributors and the Cmd+K chord actually reaches the menu.
    OpenAnythingMenuCommands(
      presentOpenAnything: presentOpenAnything,
      presentOpenAnythingSessions: presentOpenAnythingSessions,
      openAnythingCorpusSize: openAnythingCorpusSize
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
