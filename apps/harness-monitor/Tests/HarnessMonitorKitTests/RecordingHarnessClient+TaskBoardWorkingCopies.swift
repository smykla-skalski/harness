import Foundation

@testable import HarnessMonitorKit

extension RecordingHarnessClient {
  func setTaskBoardWorkingCopies(_ entries: [WorkingCopyListEntry]) {
    lock.withLock { taskBoardWorkingCopiesStorage = entries }
  }

  func taskBoardWorkingCopies() async throws -> [WorkingCopyListEntry] {
    lock.withLock { taskBoardWorkingCopiesStorage }
  }

  func obtainTaskBoardWorkingCopy(
    repository: String,
    allowClone: Bool
  ) async throws -> WorkingCopyListEntry? {
    let normalized = repository.lowercased()
    return lock.withLock {
      if let existing = taskBoardWorkingCopiesStorage.first(where: {
        $0.repoFullName.lowercased() == normalized
      }) {
        return existing
      }
      guard allowClone else { return nil }
      let entry = WorkingCopyListEntry(
        repoFullName: repository,
        repoKeySegment: "seg__\(normalized)",
        path: "/obtained/\(normalized)",
        sizeBytes: 1024,
        createdAt: "2026-07-24T00:00:00Z",
        lastUsedAt: "2026-07-24T00:00:00Z"
      )
      taskBoardWorkingCopiesStorage.append(entry)
      return entry
    }
  }

  func deleteTaskBoardWorkingCopy(repoKeySegment: String) async throws {
    lock.withLock {
      taskBoardWorkingCopiesStorage.removeAll { $0.repoKeySegment == repoKeySegment }
    }
  }
}
