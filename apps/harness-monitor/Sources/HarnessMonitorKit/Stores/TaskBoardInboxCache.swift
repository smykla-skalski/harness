import Foundation

public actor TaskBoardInboxCache {
  private let sessionCache: SessionCacheService
  private let now: @Sendable () -> Date

  public init(
    sessionCache: SessionCacheService,
    now: @escaping @Sendable () -> Date = { Date.now }
  ) {
    self.sessionCache = sessionCache
    self.now = now
  }

  public func loadSnapshot(
    limit: Int = 80,
    sessionLimit: Int = 80
  ) async -> TaskBoardInboxSnapshot {
    guard let cachedList = await sessionCache.loadSessionList() else {
      return TaskBoardInboxSnapshot(generatedAt: now(), isFromCache: true)
    }

    let normalizedSessionLimit = max(sessionLimit, 0)
    let sessions = Array(cachedList.sessions.prefix(normalizedSessionLimit))
    return await loadSnapshot(sessions: sessions, limit: limit)
  }

  public func loadSnapshot(
    sessions: [SessionSummary],
    limit: Int = 80
  ) async -> TaskBoardInboxSnapshot {
    let details = await sessionCache.loadSessionDetails(
      sessionIDs: sessions.map(\.sessionId)
    )
    let detailsByID = details.mapValues(\.detail)
    return TaskBoardInboxSnapshot(
      sessions: sessions,
      detailsBySessionID: detailsByID,
      limit: limit,
      generatedAt: now(),
      isFromCache: true
    )
  }
}

extension HarnessMonitorStore {
  public func loadCachedTaskBoardInboxSnapshot(
    limit: Int = 80,
    sessionLimit: Int = 80
  ) async -> TaskBoardInboxSnapshot {
    guard let cacheService, persistenceError == nil else {
      return TaskBoardInboxSnapshot(generatedAt: Date.now, isFromCache: true)
    }
    return await TaskBoardInboxCache(sessionCache: cacheService).loadSnapshot(
      limit: limit,
      sessionLimit: sessionLimit
    )
  }

  public func loadCachedTaskBoardInboxSnapshot(
    sessions: [SessionSummary],
    limit: Int = 80
  ) async -> TaskBoardInboxSnapshot {
    guard let cacheService, persistenceError == nil else {
      return TaskBoardInboxSnapshot(generatedAt: Date.now, isFromCache: true)
    }
    return await TaskBoardInboxCache(sessionCache: cacheService).loadSnapshot(
      sessions: sessions,
      limit: limit
    )
  }
}
