import HarnessMonitorKit

extension SessionWindowView {
  /// Builds the per-window ``AppSearchIndexUpdater`` against the current
  /// snapshot and decisions cache so reindex tasks sit in a tiny
  /// background anchor instead of wrapping the whole session window.
  var appSearchIndexUpdaterAnchor: AppSearchIndexUpdater {
    AppSearchIndexUpdater(
      model: stateCache.appSearchModel,
      index: stateCache.appSearchIndex,
      agents: snapshot?.detail?.agents ?? [],
      decisions: allSessionDecisions,
      tasks: snapshot?.detail?.tasks ?? [],
      events: snapshot?.timeline ?? []
    )
  }
}
