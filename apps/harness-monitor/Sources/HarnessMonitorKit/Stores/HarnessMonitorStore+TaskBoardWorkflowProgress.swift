import Foundation

extension HarnessMonitorStore {
  public func taskBoardItemWorkflowProgress(id: String) async
    -> TaskBoardWorkflowProgressResponse?
  {
    await readTaskBoard { client in
      try await client.taskBoardItemWorkflowProgress(id: id)
    }
  }
}
