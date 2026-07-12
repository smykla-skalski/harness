import SwiftUI

@MainActor
public final class TaskBoardSelectionDispatcher {
  public var deleteSelection: (() -> Void)?

  public init() {}

  public func performDeleteSelection() {
    deleteSelection?()
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

extension FocusedValues {
  @Entry public var harnessTaskBoardSelection: TaskBoardSelectionFocus?
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
