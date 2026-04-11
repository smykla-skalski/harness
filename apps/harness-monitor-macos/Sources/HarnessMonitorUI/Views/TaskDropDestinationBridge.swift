import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// AppKit-backed drop destination that lets us force the slashed-circle
/// reject cursor on non-actionable agent cards during a task drag.
///
/// SwiftUI's `.dropDestination(for:action:isTargeted:)` does not expose the
/// `NSDragOperation` that macOS uses to pick the cursor. Returning `.move`
/// always shows the plain drag arrow, even on invalid targets. Returning
/// `[]` from `draggingEntered(_:)` / `draggingUpdated(_:)` is the only
/// native path to the `operationNotAllowed` cursor during an active drag.
struct TaskDropDestinationBridge: NSViewRepresentable {
  let canAccept: Bool
  let onTargetingChange: (Bool) -> Void
  let onDrop: ([TaskDragPayload]) -> Bool

  func makeNSView(context: Context) -> TaskDropDestinationNSView {
    let view = TaskDropDestinationNSView()
    view.coordinator = context.coordinator
    view.registerForDraggedTypes([
      NSPasteboard.PasteboardType(UTType.harnessMonitorTask.identifier),
    ])
    return view
  }

  func updateNSView(_ nsView: TaskDropDestinationNSView, context: Context) {
    context.coordinator.canAccept = canAccept
    context.coordinator.onTargetingChange = onTargetingChange
    context.coordinator.onDrop = onDrop
  }

  func makeCoordinator() -> Coordinator {
    Coordinator(
      canAccept: canAccept,
      onTargetingChange: onTargetingChange,
      onDrop: onDrop
    )
  }

  final class Coordinator {
    var canAccept: Bool
    var onTargetingChange: (Bool) -> Void
    var onDrop: ([TaskDragPayload]) -> Bool

    init(
      canAccept: Bool,
      onTargetingChange: @escaping (Bool) -> Void,
      onDrop: @escaping ([TaskDragPayload]) -> Bool
    ) {
      self.canAccept = canAccept
      self.onTargetingChange = onTargetingChange
      self.onDrop = onDrop
    }
  }
}

final class TaskDropDestinationNSView: NSView {
  var coordinator: TaskDropDestinationBridge.Coordinator?

  override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
    guard let coordinator else {
      return []
    }
    coordinator.onTargetingChange(true)
    return coordinator.canAccept ? .move : []
  }

  override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
    guard let coordinator else {
      return []
    }
    return coordinator.canAccept ? .move : []
  }

  override func draggingExited(_ sender: NSDraggingInfo?) {
    coordinator?.onTargetingChange(false)
  }

  override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool {
    coordinator?.canAccept ?? false
  }

  override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
    guard let coordinator, coordinator.canAccept else {
      return false
    }
    let pasteboardType = NSPasteboard.PasteboardType(UTType.harnessMonitorTask.identifier)
    let items = sender.draggingPasteboard.pasteboardItems ?? []
    let payloads = items.compactMap { item -> TaskDragPayload? in
      guard let data = item.data(forType: pasteboardType) else {
        return nil
      }
      return try? JSONDecoder().decode(TaskDragPayload.self, from: data)
    }
    guard !payloads.isEmpty else {
      return false
    }
    return coordinator.onDrop(payloads)
  }

  override func concludeDragOperation(_ sender: NSDraggingInfo?) {
    coordinator?.onTargetingChange(false)
  }
}
