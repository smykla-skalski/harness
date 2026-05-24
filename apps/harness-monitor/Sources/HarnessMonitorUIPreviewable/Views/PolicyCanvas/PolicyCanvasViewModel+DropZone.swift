import SwiftUI

extension PolicyCanvasViewModel {
  /// Update the highlighted group in response to a palette-item hover. Sets
  /// `highlightedGroupID` to the group when entering, clears it on exit.
  /// `dropPalettePayloads(...)` runs first on drop and replaces the highlight
  /// with the new node's selection, so we don't need to coordinate clearing
  /// past the drop frame.
  func setGroupDropTargeted(_ targeted: Bool, groupID: String) {
    if targeted {
      highlightedGroupID = groupID
    } else if highlightedGroupID == groupID {
      highlightedGroupID = nil
    }
  }

  /// Drop a palette payload onto a group region. Routes through
  /// `dropPalettePayloads` so the node creation flows through the standard
  /// `addNode` change funnel, then arms the acceptance flash (Wave 4K P36)
  /// when the drop actually produced a node. The view-side affordance gates
  /// the visual on `accessibilityReduceMotion`; the state flip happens here
  /// either way so VoiceOver / reduced-motion clients can hook into the
  /// signal without seeing the animation.
  @discardableResult
  func dropPalettePayloadsOnGroup(
    _ payloads: [String],
    groupID: String,
    at point: CGPoint
  ) -> Bool {
    let accepted = dropPalettePayloads(payloads, at: point)
    if accepted {
      let landed = selectedNode
      triggerGroupAcceptanceFlash(groupID: groupID, landedNode: landed)
    }
    return accepted
  }

  /// Arm the acceptance-flash bit for `groupID`. Cancels any in-flight clear
  /// task so a rapid drop-drop sequence stays lit continuously; schedules a
  /// follow-up clear after `groupAcceptanceFlashDuration` so the flash has a
  /// bounded lifetime even when no further gesture fires. Tests can read
  /// the bit synchronously after a call without waiting for the timer; the
  /// view layer reads it from a SwiftUI body via the @Observable graph.
  ///
  /// When `landedNode` is non-nil and the target group has a known title,
  /// the funnel also publishes a status message ("Added <node> to <group>")
  /// to the inspector status line; the line is wired as a polite
  /// accessibility live region, so VoiceOver users hear the drop landed
  /// even though the flash itself is purely visual.
  func triggerGroupAcceptanceFlash(
    groupID: String,
    landedNode: PolicyCanvasNode? = nil
  ) {
    groupAcceptanceFlashTask?.cancel()
    groupAcceptanceFlashID = groupID
    if let landedNode, let targetGroup = group(groupID) {
      notifyStatus("Added \(landedNode.title) to \(targetGroup.title)")
    }
    groupAcceptanceFlashTask = Task { @MainActor [weak self] in
      let duration = PolicyCanvasViewModel.groupAcceptanceFlashDuration
      try? await Task.sleep(for: duration)
      guard !Task.isCancelled, let self else {
        return
      }
      if self.groupAcceptanceFlashID == groupID {
        self.groupAcceptanceFlashID = nil
      }
    }
  }

  /// Synchronous test hook that clears the flash without awaiting the timer.
  /// Production paths do not call this — the auto-clear task handles the
  /// timeline.
  func clearGroupAcceptanceFlash() {
    groupAcceptanceFlashTask?.cancel()
    groupAcceptanceFlashTask = nil
    groupAcceptanceFlashID = nil
  }
}
