extension PolicyCanvasViewModel {
  /// Ask the hosting viewport to reformat atomically: route the new layout
  /// before publishing it, so the canvas never flashes the stale projection a
  /// synchronous `reflowLayout()` shows between the node move and the async
  /// route refresh. Monotonic, like the other reflow generations - the bumped
  /// `id` is the signal the viewport's `.onChange` services; it is never
  /// cleared, so servicing it cannot retrigger or cancel itself. Only call from
  /// a surface that embeds `PolicyCanvasViewport`; with none mounted nothing
  /// reformats.
  func requestAtomicReflow(preserveManualAnchors: Bool = true, force: Bool = true) {
    let nextID = (atomicReflowRequest?.id ?? 0) &+ 1
    atomicReflowRequest = PolicyCanvasAtomicReflowRequest(
      id: nextID,
      preserveManualAnchors: preserveManualAnchors,
      force: force
    )
  }
}
