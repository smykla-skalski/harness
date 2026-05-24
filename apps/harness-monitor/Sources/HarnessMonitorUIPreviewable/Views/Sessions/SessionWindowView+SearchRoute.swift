import HarnessMonitorKit

extension SessionWindowView {
  /// Route a popover hit to the matching session-window selection. For
  /// `.timeline` hits the route changes; for the other domains the
  /// selection drills into the specific entity.
  func appSearchRouteAction(_ hit: AppSearchHit) {
    switch hit.domain {
    case .agents:
      stateCache.selectAgent(hit.id)
    case .decisions:
      stateCache.selectDecision(hit.id)
    case .tasks:
      stateCache.selectTask(hit.id)
    case .timeline:
      stateCache.selectRoute(.timeline)
    }
  }
}
