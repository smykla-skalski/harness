import Foundation
import SwiftData

extension SessionCacheService {
  public struct CacheCounts: Sendable {
    public let sessions: Int
    public let projects: Int
    public let agents: Int
    public let tasks: Int
    public let signals: Int
    public let timeline: Int
    public let observers: Int
    public let activities: Int

    public static let zero = Self(
      sessions: 0,
      projects: 0,
      agents: 0,
      tasks: 0,
      signals: 0,
      timeline: 0,
      observers: 0,
      activities: 0
    )
  }

  func recordCounts() -> CacheCounts {
    let ctx = makeContext()
    return CacheCounts(
      sessions: (try? ctx.fetchCount(FetchDescriptor<CachedSession>())) ?? 0,
      projects: (try? ctx.fetchCount(FetchDescriptor<CachedProject>())) ?? 0,
      agents: (try? ctx.fetchCount(FetchDescriptor<CachedAgent>())) ?? 0,
      tasks: (try? ctx.fetchCount(FetchDescriptor<CachedWorkItem>())) ?? 0,
      signals: (try? ctx.fetchCount(FetchDescriptor<CachedSignalRecord>())) ?? 0,
      timeline: (try? ctx.fetchCount(FetchDescriptor<CachedTimelineEntry>())) ?? 0,
      observers: (try? ctx.fetchCount(FetchDescriptor<CachedObserver>())) ?? 0,
      activities: (try? ctx.fetchCount(FetchDescriptor<CachedAgentActivity>())) ?? 0
    )
  }

  func deleteAllCacheData() -> Bool {
    let context = makeContext()
    do {
      let sessions = try context.fetch(FetchDescriptor<CachedSession>())
      for session in sessions {
        context.delete(session)
      }
      let projects = try context.fetch(FetchDescriptor<CachedProject>())
      for project in projects {
        context.delete(project)
      }
      try context.save()
      return true
    } catch {
      return false
    }
  }
}
