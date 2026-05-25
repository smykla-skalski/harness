import Foundation

public struct MobileReviewCheckSnippet: Codable, Equatable, Identifiable, Sendable {
  public var id: String
  public var name: String
  public var status: String
  public var conclusion: String
  public var checkSuiteID: String?
  public var detailsURL: String?

  public init(
    id: String,
    name: String,
    status: String,
    conclusion: String,
    checkSuiteID: String? = nil,
    detailsURL: String? = nil
  ) {
    self.id = id
    self.name = name
    self.status = status
    self.conclusion = conclusion
    self.checkSuiteID = checkSuiteID
    self.detailsURL = detailsURL
  }
}

public struct MobileReviewFileSnippet: Codable, Equatable, Identifiable, Sendable {
  public var id: String
  public var path: String
  public var changeType: String
  public var additions: UInt32
  public var deletions: UInt32
  public var viewedState: String
  public var isBinary: Bool

  public init(
    id: String,
    path: String,
    changeType: String,
    additions: UInt32,
    deletions: UInt32,
    viewedState: String,
    isBinary: Bool
  ) {
    self.id = id
    self.path = path
    self.changeType = changeType
    self.additions = additions
    self.deletions = deletions
    self.viewedState = viewedState
    self.isBinary = isBinary
  }
}

public struct MobileReviewActivitySnippet: Codable, Equatable, Identifiable, Sendable {
  public var id: String
  public var kind: String
  public var actor: String?
  public var summary: String
  public var recordedAt: Date

  public init(
    id: String,
    kind: String,
    actor: String? = nil,
    summary: String,
    recordedAt: Date
  ) {
    self.id = id
    self.kind = kind
    self.actor = actor
    self.summary = summary
    self.recordedAt = recordedAt
  }
}

public struct MobileReviewSummary: Codable, Equatable, Identifiable, Sendable {
  public let id: String
  public var stationID: String
  public var repositoryID: String?
  public var repository: String
  public var number: Int
  public var url: String?
  public var title: String
  public var author: String
  public var state: String
  public var checksSummary: String
  public var headSha: String?
  public var mergeable: String?
  public var reviewStatus: String?
  public var checkStatus: String?
  public var policyBlocked: Bool?
  public var isDraft: Bool?
  public var labels: [String]
  public var checks: [MobileReviewCheckSnippet]
  public var files: [MobileReviewFileSnippet]
  public var activity: [MobileReviewActivitySnippet]
  public var additions: UInt64
  public var deletions: UInt64
  public var requiredFailedCheckNames: [String]
  public var viewerCanUpdate: Bool
  public var viewerCanMergeAsAdmin: Bool
  public var filePaginationComplete: Bool?
  public var needsYou: Bool
  public var updatedAt: Date

  public init(
    id: String,
    stationID: String,
    repositoryID: String? = nil,
    repository: String,
    number: Int,
    url: String? = nil,
    title: String,
    author: String,
    state: String,
    checksSummary: String,
    headSha: String? = nil,
    mergeable: String? = nil,
    reviewStatus: String? = nil,
    checkStatus: String? = nil,
    policyBlocked: Bool? = nil,
    isDraft: Bool? = nil,
    labels: [String] = [],
    checks: [MobileReviewCheckSnippet] = [],
    files: [MobileReviewFileSnippet] = [],
    activity: [MobileReviewActivitySnippet] = [],
    additions: UInt64 = 0,
    deletions: UInt64 = 0,
    requiredFailedCheckNames: [String] = [],
    viewerCanUpdate: Bool = true,
    viewerCanMergeAsAdmin: Bool = false,
    filePaginationComplete: Bool? = nil,
    needsYou: Bool,
    updatedAt: Date
  ) {
    self.id = id
    self.stationID = stationID
    self.repositoryID = repositoryID
    self.repository = repository
    self.number = number
    self.url = url
    self.title = title
    self.author = author
    self.state = state
    self.checksSummary = checksSummary
    self.headSha = headSha
    self.mergeable = mergeable
    self.reviewStatus = reviewStatus
    self.checkStatus = checkStatus
    self.policyBlocked = policyBlocked
    self.isDraft = isDraft
    self.labels = labels
    self.checks = checks
    self.files = files
    self.activity = activity
    self.additions = additions
    self.deletions = deletions
    self.requiredFailedCheckNames = requiredFailedCheckNames
    self.viewerCanUpdate = viewerCanUpdate
    self.viewerCanMergeAsAdmin = viewerCanMergeAsAdmin
    self.filePaginationComplete = filePaginationComplete
    self.needsYou = needsYou
    self.updatedAt = updatedAt
  }

  enum CodingKeys: String, CodingKey {
    case id
    case stationID
    case repositoryID
    case repository
    case number
    case url
    case title
    case author
    case state
    case checksSummary
    case headSha
    case mergeable
    case reviewStatus
    case checkStatus
    case policyBlocked
    case isDraft
    case labels
    case checks
    case files
    case activity
    case additions
    case deletions
    case requiredFailedCheckNames
    case viewerCanUpdate
    case viewerCanMergeAsAdmin
    case filePaginationComplete
    case needsYou
    case updatedAt
  }

  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    self.init(
      id: try container.decode(String.self, forKey: .id),
      stationID: try container.decode(String.self, forKey: .stationID),
      repositoryID: try container.decodeIfPresent(String.self, forKey: .repositoryID),
      repository: try container.decode(String.self, forKey: .repository),
      number: try container.decode(Int.self, forKey: .number),
      url: try container.decodeIfPresent(String.self, forKey: .url),
      title: try container.decode(String.self, forKey: .title),
      author: try container.decode(String.self, forKey: .author),
      state: try container.decode(String.self, forKey: .state),
      checksSummary: try container.decode(String.self, forKey: .checksSummary),
      headSha: try container.decodeIfPresent(String.self, forKey: .headSha),
      mergeable: try container.decodeIfPresent(String.self, forKey: .mergeable),
      reviewStatus: try container.decodeIfPresent(String.self, forKey: .reviewStatus),
      checkStatus: try container.decodeIfPresent(String.self, forKey: .checkStatus),
      policyBlocked: try container.decodeIfPresent(Bool.self, forKey: .policyBlocked),
      isDraft: try container.decodeIfPresent(Bool.self, forKey: .isDraft),
      labels: try container.decodeIfPresent([String].self, forKey: .labels) ?? [],
      checks: try container.decodeIfPresent([MobileReviewCheckSnippet].self, forKey: .checks)
        ?? [],
      files: try container.decodeIfPresent([MobileReviewFileSnippet].self, forKey: .files) ?? [],
      activity: try container.decodeIfPresent(
        [MobileReviewActivitySnippet].self,
        forKey: .activity
      ) ?? [],
      additions: try container.decodeIfPresent(UInt64.self, forKey: .additions) ?? 0,
      deletions: try container.decodeIfPresent(UInt64.self, forKey: .deletions) ?? 0,
      requiredFailedCheckNames: try container.decodeIfPresent(
        [String].self,
        forKey: .requiredFailedCheckNames
      ) ?? [],
      viewerCanUpdate: try container.decodeIfPresent(Bool.self, forKey: .viewerCanUpdate) ?? true,
      viewerCanMergeAsAdmin: try container.decodeIfPresent(
        Bool.self,
        forKey: .viewerCanMergeAsAdmin
      ) ?? false,
      filePaginationComplete: try container.decodeIfPresent(
        Bool.self,
        forKey: .filePaginationComplete
      ),
      needsYou: try container.decode(Bool.self, forKey: .needsYou),
      updatedAt: try container.decode(Date.self, forKey: .updatedAt)
    )
  }

  public func commandDraft(
    kind: MobileCommandKind,
    targetRevision: Int64,
    label: String? = nil,
    mergeMethod: String? = nil,
    auditReason: String? = nil,
    expiresAfter: TimeInterval = 15 * 60
  ) -> MobileCommandDraft {
    var payload = commandPayload
    if let label = trimmedPayloadValue(label) {
      payload["label"] = label
    }
    if let mergeMethod = trimmedPayloadValue(mergeMethod) {
      payload["method"] = mergeMethod
    }
    return MobileCommandDraft(
      kind: kind,
      confirmationText: confirmationText(for: kind, label: label, mergeMethod: mergeMethod),
      auditReason: auditReason,
      target: MobileCommandTarget(
        stationID: stationID,
        reviewID: id,
        targetRevision: targetRevision
      ),
      payload: payload,
      expiresAfter: expiresAfter
    )
  }

  public var commandPayload: [String: String] {
    var payload: [String: String] = [
      "pullRequestID": id,
      "repository": repository,
      "number": String(number),
    ]
    payload["repositoryID"] = trimmedPayloadValue(repositoryID)
    payload["url"] = trimmedPayloadValue(url)
    payload["headSha"] = trimmedPayloadValue(headSha)
    payload["mergeable"] = trimmedPayloadValue(mergeable)
    payload["reviewStatus"] = trimmedPayloadValue(reviewStatus)
    payload["checkStatus"] = trimmedPayloadValue(checkStatus)
    payload["state"] = trimmedPayloadValue(state)
    payload["requiredFailedCheckNames"] = csvPayload(requiredFailedCheckNames)
    payload["checkSuiteIDs"] = csvPayload(checks.compactMap(\.checkSuiteID))
    payload["viewerCanUpdate"] = viewerCanUpdate ? "true" : "false"
    payload["viewerCanMergeAsAdmin"] = viewerCanMergeAsAdmin ? "true" : "false"
    if let policyBlocked {
      payload["policyBlocked"] = policyBlocked ? "true" : "false"
    }
    if let isDraft {
      payload["isDraft"] = isDraft ? "true" : "false"
    }
    return payload
  }

  private func csvPayload(_ values: [String]) -> String? {
    let trimmedValues = values.compactMap(trimmedPayloadValue)
    return trimmedValues.isEmpty ? nil : trimmedValues.joined(separator: ",")
  }

  private func confirmationText(
    for kind: MobileCommandKind,
    label: String?,
    mergeMethod: String?
  ) -> String {
    let target = "\(repository) #\(number)"
    switch kind {
    case .pullRequestApprove:
      return "Approve \(target)."
    case .pullRequestLabel:
      let label = trimmedPayloadValue(label) ?? "label"
      return "Apply label \(label) to \(target)."
    case .pullRequestRerunChecks:
      return "Rerun checks for \(target)."
    case .pullRequestMerge:
      let method = trimmedPayloadValue(mergeMethod) ?? "squash"
      return "Merge \(target) with \(method)."
    case .refresh:
      return "Refresh \(target)."
    default:
      return "\(kind.title) for \(target)."
    }
  }

  private func trimmedPayloadValue(_ value: String?) -> String? {
    guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines),
      !value.isEmpty
    else {
      return nil
    }
    return value
  }
}
