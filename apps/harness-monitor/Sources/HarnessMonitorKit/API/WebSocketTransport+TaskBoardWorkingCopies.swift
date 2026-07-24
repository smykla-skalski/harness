import Foundation

extension WebSocketTransport {
  public func taskBoardWorkingCopies() async throws -> [WorkingCopyListEntry] {
    let value = try await rpc(method: .taskBoardWorkingCopiesList, params: nil)
    return try decodePolicyWire(value)
  }

  public func obtainTaskBoardWorkingCopy(
    repository: String,
    allowClone: Bool
  ) async throws -> WorkingCopyListEntry? {
    let params = try encodeParams(
      TaskBoardWorkingCopyObtainRequest(repository: repository, allowClone: allowClone),
      extra: [:]
    )
    let value = try await rpc(method: .taskBoardWorkingCopiesObtain, params: params)
    // The WS twin forwards the raw service result: the entry, or null when a
    // missing checkout was not cloned (allowClone false).
    let entry: WorkingCopyListEntry? = try decodePolicyWire(value)
    return entry
  }

  public func deleteTaskBoardWorkingCopy(repoKeySegment: String) async throws {
    let params = try encodeParams(
      TaskBoardWorkingCopyDeleteRequest(repoKeySegment: repoKeySegment),
      extra: [:]
    )
    _ = try await rpc(method: .taskBoardWorkingCopiesDelete, params: params)
  }
}
