import Foundation

/// Empty body for the working-copies list POST; the daemon ignores it.
public struct TaskBoardWorkingCopiesListRequest: Codable, Equatable, Sendable {
  public init() {}
}

public struct TaskBoardWorkingCopyObtainRequest: Codable, Equatable, Sendable {
  public let repository: String
  /// When false the daemon resolves-or-reports-absent; when true it clones a
  /// missing checkout. Delivery passes false, the explicit action passes true.
  public let allowClone: Bool

  public init(repository: String, allowClone: Bool) {
    self.repository = repository
    self.allowClone = allowClone
  }

  enum CodingKeys: String, CodingKey {
    case repository
    case allowClone = "allow_clone"
  }
}

/// HTTP obtain response. `present` mirrors `entry != nil`; the app keys off the
/// entry itself, so both transports funnel down to `WorkingCopyListEntry?`.
public struct TaskBoardWorkingCopyObtainResponse: Codable, Equatable, Sendable {
  public let present: Bool
  public let entry: WorkingCopyListEntry?

  public init(present: Bool, entry: WorkingCopyListEntry?) {
    self.present = present
    self.entry = entry
  }
}

public struct TaskBoardWorkingCopyDeleteRequest: Codable, Equatable, Sendable {
  public let repoKeySegment: String

  public init(repoKeySegment: String) {
    self.repoKeySegment = repoKeySegment
  }

  enum CodingKeys: String, CodingKey {
    case repoKeySegment = "repo_key_segment"
  }
}

extension WorkingCopyListEntry: Identifiable {
  public var id: String { repoKeySegment }
}

extension HarnessMonitorAPIClient {
  public func taskBoardWorkingCopies() async throws -> [WorkingCopyListEntry] {
    try await post(
      "/v1/task-board/working-copies",
      body: TaskBoardWorkingCopiesListRequest(),
      decoder: PolicyWireCoding.decoder
    )
  }

  public func obtainTaskBoardWorkingCopy(
    repository: String,
    allowClone: Bool
  ) async throws -> WorkingCopyListEntry? {
    let response: TaskBoardWorkingCopyObtainResponse = try await post(
      "/v1/task-board/working-copies/obtain",
      body: TaskBoardWorkingCopyObtainRequest(repository: repository, allowClone: allowClone),
      decoder: PolicyWireCoding.decoder
    )
    return response.entry
  }

  public func deleteTaskBoardWorkingCopy(repoKeySegment: String) async throws {
    // The daemon returns the post-delete listing, but the caller refetches, so
    // the body is decoded structurally and discarded.
    let _: JSONValue = try await post(
      "/v1/task-board/working-copies/delete",
      body: TaskBoardWorkingCopyDeleteRequest(repoKeySegment: repoKeySegment)
    )
  }
}
