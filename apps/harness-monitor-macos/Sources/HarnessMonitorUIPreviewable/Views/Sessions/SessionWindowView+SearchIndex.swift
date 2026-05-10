import HarnessMonitorKit

extension SessionWindowView {
  /// Builds the per-window ``AppSearchIndexUpdater`` against the current
  /// snapshot and decisions cache so the body composition can apply it
  /// in a single line.
  var appSearchIndexUpdaterModifier: AppSearchIndexUpdater {
    AppSearchIndexUpdater(
      index: stateCache.appSearchIndex,
      agents: snapshot?.detail?.agents ?? [],
      decisions: allSessionDecisions,
      tasks: snapshot?.detail?.tasks ?? [],
      events: snapshot?.timeline ?? []
    )
  }
}
