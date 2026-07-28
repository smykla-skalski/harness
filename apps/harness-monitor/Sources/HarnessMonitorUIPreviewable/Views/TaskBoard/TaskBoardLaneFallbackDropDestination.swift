import SwiftUI

private struct TaskBoardLaneFallbackDropDestination: ViewModifier {
  let acceptsDrop: () -> Bool
  let insertionOffset: Int
  let action: ([TaskBoardCardDragPayload], Int) -> Bool

  func body(content: Content) -> some View {
    content
      .dropDestination(for: TaskBoardCardDragPayload.self) { payloads, _ in
        guard acceptsDrop() else {
          traceTaskBoardCardDrag("fallback-destination rejected")
          return
        }
        traceTaskBoardCardDrag(
          "fallback-destination offset=\(insertionOffset) payloads=\(payloads.count)"
        )
        _ = action(payloads, insertionOffset)
      }
      // Resolve as a MOVE, not the default copy: a copy leaves the source in place, so
      // AppKit animates the preview back to origin before our commit lands (the fly-back).
      .dropConfiguration { _ in
        DropConfiguration(operation: acceptsDrop() ? .move : .forbidden)
      }
  }
}

extension View {
  func taskBoardLaneFallbackDropDestination(
    acceptsDrop: @escaping () -> Bool,
    insertionOffset: Int,
    action: @escaping ([TaskBoardCardDragPayload], Int) -> Bool
  ) -> some View {
    modifier(
      TaskBoardLaneFallbackDropDestination(
        acceptsDrop: acceptsDrop,
        insertionOffset: insertionOffset,
        action: action
      )
    )
  }
}
