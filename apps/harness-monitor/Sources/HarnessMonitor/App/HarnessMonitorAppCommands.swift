import HarnessMonitorKit
import HarnessMonitorPolicyCanvas
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
  @FocusedValue(\.harnessTaskBoardCommandFocus)
  private var taskBoardCommandFocus
  @FocusedValue(\.dashboardAuditCopyCommand)
  private var dashboardAuditCopyFocus
  @FocusedValue(\.harnessPolicyCanvasCommandFocus)
  private var policyCanvasCommandFocus
  let store: HarnessMonitorStore
  let displayState: CommandsDisplayState
  let textSizeIndex: Int
  let increaseTextSize: () -> Void
  let decreaseTextSize: () -> Void
  let resetTextSize: () -> Void
  let refreshStore: () -> Void

  private var canIncreaseTextSize: Bool {
    HarnessMonitorTextSize.canIncrease(textSizeIndex)
  }

  private var canDecreaseTextSize: Bool {
    HarnessMonitorTextSize.canDecrease(textSizeIndex)
  }

  private var hasPolicyCanvasZoomFocus: Bool {
    policyCanvasCommandFocus != nil
  }

  private var policyCanvasZoomFocus: PolicyCanvasZoomFocus? {
    policyCanvasCommandFocus?.zoom
  }

  private var policyCanvasLayoutFocus: PolicyCanvasLayoutFocus? {
    policyCanvasCommandFocus?.layout
  }

  private var hasPolicyCanvasLayoutFocus: Bool {
    policyCanvasLayoutFocus != nil
  }

  private var policyCanvasSaveFocus: PolicyCanvasSaveFocus? {
    policyCanvasCommandFocus?.save
  }

  private var hasPolicyCanvasSaveFocus: Bool {
    policyCanvasSaveFocus != nil
  }

  private var policyCanvasInspectorFocus: PolicyCanvasInspectorFocus? {
    policyCanvasCommandFocus?.inspector
  }

  private var policyCanvasInspectorMenuTitle: String {
    policyCanvasInspectorFocus?.isVisible == true
      ? "Hide Policy Inspector"
      : "Show Policy Inspector"
  }

  private var searchCommandTitle: LocalizedStringKey {
    searchFocusAction?.menuLabel.localizedTitle ?? "Find"
  }

  private var taskBoardSelectionFocus: TaskBoardSelectionFocus? {
    taskBoardCommandFocus?.selection
  }

  private var deleteSelectionCommandTitle: String {
    taskBoardSelectionFocus == nil
      ? "Delete Sidebar Selection"
      : "Delete Task Board Selection"
  }

  private var canDeleteFocusedSelection: Bool {
    if let taskBoardSelectionFocus {
      return taskBoardSelectionFocus.canDelete
    }
    return sidebarSelectionFocus?.canDelete == true
  }

  var body: some Commands {
    systemCommands
    fileAndEditCommands
    dashboardAuditCopyCommands
    viewCommands
    policyCanvasZoomCommands
    policyCanvasLayoutCommands
    policyCanvasInspectorCommands
    policyCanvasSaveCommands
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
    searchCommands
    sidebarSelectionCommands
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
      Button(deleteSelectionCommandTitle) {
        performDeleteFocusedSelection()
      }
      .keyboardShortcut(.delete, modifiers: [])
      .disabled(!canDeleteFocusedSelection)
    }
  }

  private func performDeleteFocusedSelection() {
    if let taskBoardSelectionFocus {
      taskBoardSelectionFocus.performDeleteSelection()
      return
    }
    sidebarSelectionFocus?.dispatcher.performDeleteSelection()
  }

  @CommandsBuilder private var dashboardAuditCopyCommands: some Commands {
    if let dashboardAuditCopyFocus, dashboardAuditCopyFocus.canCopy {
      CommandGroup(replacing: .pasteboard) {
        Button("Cut") {}
          .keyboardShortcut("x", modifiers: .command)
          .disabled(true)
        Button("Copy Audit Event") {
          dashboardAuditCopyFocus.copy()
        }
        .keyboardShortcut("c", modifiers: .command)
        Button("Paste") {}
          .keyboardShortcut("v", modifiers: .command)
          .disabled(true)
      }
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

  @CommandsBuilder private var policyCanvasLayoutCommands: some Commands {
    CommandGroup(after: .toolbar) {
      if let layoutFocus = policyCanvasLayoutFocus {
        Button("Reformat Canvas") {
          layoutFocus.dispatcher.performReflowLayout()
        }
        .keyboardShortcut("l", modifiers: [.command, .shift])
        .disabled(!layoutFocus.canReflow)
      } else {
        Button("Reformat Canvas") {
          policyCanvasLayoutFocus?.dispatcher.performReflowLayout()
        }
        .disabled(!hasPolicyCanvasLayoutFocus)
      }
    }
  }

  @CommandsBuilder private var policyCanvasInspectorCommands: some Commands {
    CommandGroup(after: .toolbar) {
      if let inspectorFocus = policyCanvasInspectorFocus {
        Button(policyCanvasInspectorMenuTitle) {
          inspectorFocus.dispatcher.performToggleInspector()
        }
        .disabled(!inspectorFocus.canToggle)
      } else {
        Button("Show Policy Inspector") {
          policyCanvasInspectorFocus?.dispatcher.performToggleInspector()
        }
        .disabled(true)
      }
    }
  }

  @CommandsBuilder private var policyCanvasSaveCommands: some Commands {
    CommandGroup(after: .saveItem) {
      if let saveFocus = policyCanvasSaveFocus {
        Button("Save Policy Canvas") {
          saveFocus.dispatcher.performSave()
        }
        .keyboardShortcut("s", modifiers: .command)
        .disabled(!saveFocus.canSave)
      } else {
        Button("Save Policy Canvas") {
          policyCanvasSaveFocus?.dispatcher.performSave()
        }
        .disabled(!hasPolicyCanvasSaveFocus)
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
