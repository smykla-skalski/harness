import Foundation
import SwiftData

extension SessionCacheService {
  /// Upsert the V8 `CachedTaskReviewMetadata` side-table for every task
  /// that carries review state. Tasks with an empty review block are
  /// deleted from the side-table so callers can treat a missing row as
  /// "no review metadata". Rows whose task is no longer present in the
  /// incoming set are removed to keep the cache consistent.
  func syncReviewMetadata(
    _ tasks: [WorkItem],
    sessionID: String,
    incomingIds: Set<String>,
    context: ModelContext
  ) {
    let descriptor = FetchDescriptor<CachedTaskReviewMetadata>(
      predicate: #Predicate { $0.sessionId == sessionID }
    )
    let existingRows = (try? context.fetch(descriptor)) ?? []
    let existingByTask = Dictionary(uniqueKeysWithValues: existingRows.map { ($0.taskId, $0) })

    for task in tasks {
      let blob = encodedReviewMetadata(for: task)
      if let blob {
        if let row = existingByTask[task.taskId] {
          row.reviewBlob = blob
          row.updatedAt = .now
        } else {
          context.insert(
            CachedTaskReviewMetadata(
              sessionId: sessionID,
              taskId: task.taskId,
              reviewBlob: blob
            )
          )
        }
      } else if let row = existingByTask[task.taskId] {
        context.delete(row)
      }
    }

    for row in existingRows where !incomingIds.contains(row.taskId) {
      context.delete(row)
    }
  }
}
