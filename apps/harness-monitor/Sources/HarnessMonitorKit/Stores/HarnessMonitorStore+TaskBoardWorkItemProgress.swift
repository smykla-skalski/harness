import Foundation

extension HarnessMonitorStore {
  public func taskBoardItemProgress(id: String) async -> TaskBoardWorkItemProgressResponse? {
    await readTaskBoard { client in
      try await client.taskBoardItemProgress(id: id)
    }
  }
}
