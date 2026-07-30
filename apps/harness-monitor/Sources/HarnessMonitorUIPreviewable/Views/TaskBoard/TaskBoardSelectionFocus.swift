import SwiftUI

enum TaskBoardSelectionRequest: Equatable {
  case delete
  case open
  case openSpawnedTask
}

@MainActor
@Observable
public final class TaskBoardSelectionDispatcher {
  private(set) var requestGeneration: UInt64 = 0
  private(set) var latestRequest: TaskBoardSelectionRequest?

  public init() {}

  public func performDeleteSelection() {
    submit(.delete)
  }

  func performOpenSelection() {
    submit(.open)
  }

  func performOpenSpawnedTask() {
    submit(.openSpawnedTask)
  }

  private func submit(_ request: TaskBoardSelectionRequest) {
    latestRequest = request
    requestGeneration &+= 1
  }
}

public struct TaskBoardSelectionFocus: Equatable {
  public let selectionCount: Int
  public let canDelete: Bool
  let canOpen: Bool
  let canOpenSpawnedTask: Bool
  public let dispatcher: TaskBoardSelectionDispatcher

  public init(
    selectionCount: Int,
    canDelete: Bool,
    dispatcher: TaskBoardSelectionDispatcher
  ) {
    self.init(
      selectionCount: selectionCount,
      canDelete: canDelete,
      canOpen: false,
      canOpenSpawnedTask: false,
      dispatcher: dispatcher
    )
  }

  init(
    selectionCount: Int,
    canDelete: Bool,
    canOpen: Bool,
    canOpenSpawnedTask: Bool,
    dispatcher: TaskBoardSelectionDispatcher
  ) {
    self.selectionCount = selectionCount
    self.canDelete = canDelete
    self.canOpen = canOpen
    self.canOpenSpawnedTask = canOpenSpawnedTask
    self.dispatcher = dispatcher
  }

  @MainActor
  public func performDeleteSelection() {
    guard canDelete else { return }
    dispatcher.performDeleteSelection()
  }

  @MainActor
  func performOpenSelection() {
    guard canOpen else { return }
    dispatcher.performOpenSelection()
  }

  @MainActor
  func performOpenSpawnedTask() {
    guard canOpenSpawnedTask else { return }
    dispatcher.performOpenSpawnedTask()
  }

  public static func == (lhs: Self, rhs: Self) -> Bool {
    lhs.selectionCount == rhs.selectionCount
      && lhs.canDelete == rhs.canDelete
      && lhs.canOpen == rhs.canOpen
      && lhs.canOpenSpawnedTask == rhs.canOpenSpawnedTask
      && lhs.dispatcher === rhs.dispatcher
  }
}

public struct TaskBoardCommandFocus: Equatable {
  public let selection: TaskBoardSelectionFocus
  public let operationsInspector: TaskBoardOperationsInspectorFocus?

  public init(
    selection: TaskBoardSelectionFocus,
    operationsInspector: TaskBoardOperationsInspectorFocus?
  ) {
    self.selection = selection
    self.operationsInspector = operationsInspector
  }
}

extension FocusedValues {
  /// Publish one Task Board-focused value so selection and inspector changes
  /// cannot produce multiple same-frame FocusedValue updates from the route.
  @Entry public var harnessTaskBoardCommandFocus: TaskBoardCommandFocus?
}

extension View {
  /// Mount at the Task Board root beside its focused selection value. The Edit
  /// menu owns Backspace; this hidden button adds Forward Delete without a
  /// duplicate visible command.
  func taskBoardSelectionShortcuts(
    _ focus: TaskBoardSelectionFocus?
  ) -> some View {
    overlay {
      if let focus {
        Group {
          Button("Forward Delete Task Board Selection") {
            focus.performDeleteSelection()
          }
          .keyboardShortcut(.deleteForward, modifiers: [])
          .disabled(!focus.canDelete)

          Button("Open Task Board Ticket") {
            focus.performOpenSelection()
          }
          .keyboardShortcut(.return, modifiers: [])
          .disabled(!focus.canOpen)

          Button("Open Spawned Task") {
            focus.performOpenSpawnedTask()
          }
          .keyboardShortcut(.return, modifiers: .command)
          .disabled(!focus.canOpenSpawnedTask)
        }
        .opacity(0)
        .frame(width: 0, height: 0)
        .accessibilityHidden(true)
      }
    }
  }

  public func taskBoardSelectionForwardDeleteShortcut(
    _ focus: TaskBoardSelectionFocus?
  ) -> some View {
    taskBoardSelectionShortcuts(focus)
  }
}
