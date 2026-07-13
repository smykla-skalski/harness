import SwiftUI

@MainActor
@Observable
public final class TaskBoardSelectionDispatcher {
  public private(set) var deleteRequestGeneration: UInt64 = 0

  public init() {}

  public func performDeleteSelection() {
    deleteRequestGeneration &+= 1
  }
}

public struct TaskBoardSelectionFocus: Equatable {
  public let selectionCount: Int
  public let canDelete: Bool
  public let dispatcher: TaskBoardSelectionDispatcher

  public init(
    selectionCount: Int,
    canDelete: Bool,
    dispatcher: TaskBoardSelectionDispatcher
  ) {
    self.selectionCount = selectionCount
    self.canDelete = canDelete
    self.dispatcher = dispatcher
  }

  @MainActor
  public func performDeleteSelection() {
    guard canDelete else { return }
    dispatcher.performDeleteSelection()
  }

  public static func == (lhs: Self, rhs: Self) -> Bool {
    lhs.selectionCount == rhs.selectionCount
      && lhs.canDelete == rhs.canDelete
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
  public func taskBoardSelectionForwardDeleteShortcut(
    _ focus: TaskBoardSelectionFocus?
  ) -> some View {
    overlay {
      if let focus {
        Button("Forward Delete Task Board Selection") {
          focus.performDeleteSelection()
        }
        .keyboardShortcut(.deleteForward, modifiers: [])
        .disabled(!focus.canDelete)
        .opacity(0)
        .frame(width: 0, height: 0)
        .accessibilityHidden(true)
      }
    }
  }
}
