import Foundation

extension HarnessMonitorStore {
  public func recentSessionIDsForLaunchWindows(limit: Int) async -> [String] {
    let normalizedLimit = max(limit, 0)
    guard normalizedLimit > 0 else { return [] }

    var sessionIDs = await recentlyViewedSessionIDs(limit: normalizedLimit)
    appendFallbackRecentSessionIDs(to: &sessionIDs, limit: normalizedLimit)
    return Array(sessionIDs.prefix(normalizedLimit))
  }

  private func recentlyViewedSessionIDs(limit: Int) async -> [String] {
    guard let cacheService else { return [] }
    let knownSessionIDs = Set(sessionIndex.catalog.sessions.map(\.sessionId))
    return await cacheService.recentlyViewedSessionIDs(limit: limit)
      .filter { knownSessionIDs.contains($0) }
  }

  private func appendFallbackRecentSessionIDs(to sessionIDs: inout [String], limit: Int) {
    var seen = Set(sessionIDs)
    for summary in sessionIndex.catalog.recentSessions where sessionIDs.count < limit {
      guard seen.insert(summary.sessionId).inserted else {
        continue
      }
      sessionIDs.append(summary.sessionId)
    }
  }
}
