import Foundation
import SwiftData
import os

extension UserDataPersistenceService {
  static let signposter = OSSignposter(
    subsystem: "io.harnessmonitor",
    category: "persistence"
  )
  static let maxAuditEventCacheRecords = 1_000

  func pruneAuditEvents(context: ModelContext, maximumCount: Int) throws {
    let descriptor = FetchDescriptor<AuditEventRecord>(
      sortBy: [
        SortDescriptor(\.recordedAt, order: .reverse),
        SortDescriptor(\.eventID, order: .forward),
      ]
    )
    let records = try context.fetch(descriptor)
    guard maximumCount > 0 else {
      for record in records {
        context.delete(record)
      }
      return
    }
    guard records.count > maximumCount else {
      return
    }
    for record in records.dropFirst(maximumCount) {
      context.delete(record)
    }
  }

  func taskUserNoteDescriptor(
    taskID: String,
    sessionID: String
  ) -> FetchDescriptor<UserNote> {
    let targetKind = "task"
    let targetID = taskID
    let selectedSessionID = sessionID
    return FetchDescriptor<UserNote>(
      predicate: #Predicate<UserNote> { note in
        note.targetKind == targetKind
          && note.targetId == targetID
          && note.sessionId == selectedSessionID
      }
    )
  }

  func deleteAllRecords<T: PersistentModel>(
    _ type: T.Type,
    in context: ModelContext
  ) throws {
    let items = try context.fetch(FetchDescriptor<T>())
    for item in items {
      context.delete(item)
    }
  }

  func count<T: PersistentModel>(_ type: T.Type, in context: ModelContext) -> Int {
    (try? context.fetchCount(FetchDescriptor<T>())) ?? 0
  }

  func withPersistenceSignpost<Result>(
    _ name: StaticString,
    _ operation: () throws -> Result
  ) rethrows -> Result {
    let signpostID = Self.signposter.makeSignpostID()
    let interval = Self.signposter.beginInterval(name, id: signpostID)
    defer {
      Self.signposter.endInterval(name, interval)
    }
    return try operation()
  }
}
