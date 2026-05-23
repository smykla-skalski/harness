import HarnessMonitorKit
import HarnessMonitorUIPreviewable
import SwiftUI

struct HarnessMonitorAppCommands: Commands {
  private static var documentationURL: URL {
    guard let documentationURL = URL(string: "https://github.com/smykla-skalski/harness") else {
      preconditionFailure("Harness documentation URL must remain valid")
    }
    return documentationURL
  }

  @Environment(\.openWindow)
  private var openWindow
  @FocusedValue(\.harnessSidebarSearchFocusAction)
  private var searchFocusAction
  @FocusedValue(\.harnessSessionSidebarSelection)
  private var sidebarSelectionFocus
  @FocusedValue(\.harnessPolicyCanvasZoomFocus)
  private var policyCanvasZoomFocus
  let store: HarnessMonitorStore
  let displayState: CommandsDisplayState
  let textSizeIndex: Int
  let increaseTextSize: () -> Void
  let decreaseTextSize: () -> Void
  let resetTextSize: () -> Void
  let refreshStore: () -> Void
  let presentOpenAnything: () -> Void
  let presentOpenAnythingSessions: () -> Void
  let openAnythingCorpusSize: () -> Int

  private var canIncreaseTextSize: Bool {
    HarnessMonitorTextSize.canIncrease(textSizeIndex)
  }

  private var canDecreaseTextSize: Bool {
    HarnessMonitorTextSize.canDecrease(textSizeIndex)
  }

  private var hasPolicyCanvasZoomFocus: Bool {
    policyCanvasZoomFocus != nil
  }

  private var searchCommandTitle: LocalizedStringKey {
    searchFocusAction?.menuLabel.localizedTitle ?? "Find"
  }

  var body: some Commands {
    systemCommands
    fileAndEditCommands
    viewCommands
    policyCanvasZoomCommands
    helpCommands
  }

  @CommandsBuilder private var systemCommands: some Commands {
    SidebarCommands()
    TextEditingCommands()
    CommandGroup(replacing: .appSettings) {
      Button("Settings…") {
        openWindow(id: HarnessMonitorWindowID.settings)
      }
      .keyboardShortcut(",", modifiers: .command)
    }
  }

  @CommandsBuilder private var fileAndEditCommands: some Commands {
    CommandGroup(after: .newItem) {
      Button("New Task") {
        store.requestCreateTaskSheet()
      }
      .disabled(!displayState.hasSelectedSession || displayState.isSessionReadOnly)
      Button("Send Signal") {
        store.presentSendSignalSheetForSelectedSessionLeader()
      }
      .keyboardShortcut("s", modifiers: [.command, .shift])
      .disabled(!displayState.hasSelectedSession || displayState.isSessionReadOnly)
    }
    openAnythingCommands
    searchCommands
    sidebarSelectionCommands
  }

  // Audit #11: Open Anything anchors to the File menu (after `.newItem`) so the
  // Cmd+K chord lives alongside New Task / Send Signal rather than under Edit's
  // pasteboard cluster.
  // Audit #78: Cmd+Shift+K opens the palette scoped to the `.sessions` domain
  // so users can quick-switch between session windows without ever seeing
  // settings or action results.
  // Audit #96: in DEBUG builds the menu title carries the current corpus size
  // so the engineer can spot stale-corpus regressions at a glance.
  @CommandsBuilder private var openAnythingCommands: some Commands {
    CommandGroup(after: .newItem) {
      Button(openAnythingMenuTitle, action: presentOpenAnything)
        .keyboardShortcut("k", modifiers: .command)
      Button("Open Anything (Sessions)", action: presentOpenAnythingSessions)
        .keyboardShortcut("k", modifiers: [.command, .shift])
    }
  }

  private var openAnythingMenuTitle: LocalizedStringKey {
    #if DEBUG
      "Open Anything (\(openAnythingCorpusSize()))"
    #else
      "Open Anything"
    #endif
  }

  @CommandsBuilder private var searchCommands: some Commands {
    CommandGroup(after: .pasteboard) {
      Button(searchCommandTitle) {
        searchFocusAction?.invoke()
      }
      .keyboardShortcut("f", modifiers: .command)
      .disabled(searchFocusAction?.isAvailable != true)
    }
  }

  @CommandsBuilder private var sidebarSelectionCommands: some Commands {
    CommandGroup(after: .pasteboard) {
      Divider()
      Button("Select All in Sidebar") {
        sidebarSelectionFocus?.dispatcher.performSelectAll()
      }
      .keyboardShortcut("a", modifiers: [.command, .option])
      .disabled(sidebarSelectionFocus == nil)
      Button("Clear Sidebar Selection") {
        sidebarSelectionFocus?.dispatcher.performClearSelection()
      }
      .keyboardShortcut(.escape, modifiers: [])
      .disabled(sidebarSelectionFocus?.hasMultiSelection != true)
      Button("Delete Sidebar Selection") {
        sidebarSelectionFocus?.dispatcher.performDeleteSelection()
      }
      .keyboardShortcut(.delete, modifiers: [])
      .disabled(sidebarSelectionFocus?.canDelete != true)
    }
  }

  @CommandsBuilder private var viewCommands: some Commands {
    CommandGroup(after: .toolbar) {
      // Keep inactive menu items visible, but only the active surface owns the
      // key equivalents. AppKit can resolve Cmd-- / Cmd-0 against a disabled
      // duplicate before the dashboard text-size action sees the chord.
      if hasPolicyCanvasZoomFocus {
        Button("Increase Text Size", action: increaseTextSize)
          .disabled(true)
      } else {
        Button("Increase Text Size", action: increaseTextSize)
          .keyboardShortcut("+", modifiers: .command)
          .disabled(!canIncreaseTextSize)
      }

      if hasPolicyCanvasZoomFocus {
        Button("Decrease Text Size", action: decreaseTextSize)
          .disabled(true)
      } else {
        Button("Decrease Text Size", action: decreaseTextSize)
          .keyboardShortcut("-", modifiers: .command)
          .disabled(!canDecreaseTextSize)
      }

      if hasPolicyCanvasZoomFocus {
        Button("Reset Text Size", action: resetTextSize)
          .disabled(true)
      } else {
        Button("Reset Text Size", action: resetTextSize)
          .keyboardShortcut("0", modifiers: .command)
          .disabled(textSizeIndex == HarnessMonitorTextSize.defaultIndex)
      }

      Divider()

      Button("Refresh", action: refreshStore)
        .keyboardShortcut("r", modifiers: [.command])
    }
  }

  /// Scene-level keyboard shortcuts for canvas zoom. Bind Cmd-=, Cmd--, and
  /// Cmd-0 only when a canvas owns scene focus. The inactive menu items stay
  /// visible but unbound so AppKit does not route those chords into a disabled
  /// duplicate before the active command handles them.
  ///
  /// The visible zoom HUD buttons on `PolicyCanvasZoomControls` stay
  /// clickable but no longer carry `.keyboardShortcut` modifiers; one source
  /// of truth for the chords keeps menu and responder-chain behavior
  /// auditable from a single file.
  @CommandsBuilder private var policyCanvasZoomCommands: some Commands {
    CommandGroup(after: .toolbar) {
      if let zoomFocus = policyCanvasZoomFocus {
        Button("Zoom In") {
          zoomFocus.dispatcher.performZoomIn()
        }
        .keyboardShortcut("=", modifiers: .command)
      } else {
        Button("Zoom In") {
          policyCanvasZoomFocus?.dispatcher.performZoomIn()
        }
        .disabled(true)
      }

      if let zoomFocus = policyCanvasZoomFocus {
        Button("Zoom Out") {
          zoomFocus.dispatcher.performZoomOut()
        }
        .keyboardShortcut("-", modifiers: .command)
      } else {
        Button("Zoom Out") {
          policyCanvasZoomFocus?.dispatcher.performZoomOut()
        }
        .disabled(true)
      }

      if let zoomFocus = policyCanvasZoomFocus {
        Button("Reset Zoom") {
          zoomFocus.dispatcher.performResetZoom()
        }
        .keyboardShortcut("0", modifiers: .command)
      } else {
        Button("Reset Zoom") {
          policyCanvasZoomFocus?.dispatcher.performResetZoom()
        }
        .disabled(true)
      }
    }
  }

  @CommandsBuilder private var helpCommands: some Commands {
    CommandGroup(after: .help) {
      Link(
        "Harness Monitor Documentation",
        destination: Self.documentationURL
      )
    }
  }
}
