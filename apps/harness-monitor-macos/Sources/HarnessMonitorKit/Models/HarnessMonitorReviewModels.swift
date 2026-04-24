import Foundation

public struct AwaitingReview: Codable, Equatable, Sendable {
  public let queuedAt: String
  public let submitterAgentId: String
  public let summary: String?
  public let requiredConsensus: Int

  public init(
    queuedAt: String,
    submitterAgentId: String,
    summary: String? = nil,
    requiredConsensus: Int = 2
  ) {
    self.queuedAt = queuedAt
    self.submitterAgentId = submitterAgentId
    self.summary = summary
    self.requiredConsensus = requiredConsensus
  }

  enum CodingKeys: String, CodingKey {
    case queuedAt, submitterAgentId, summary, requiredConsensus
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    self.init(
      queuedAt: try container.decode(String.self, forKey: .queuedAt),
      submitterAgentId: try container.decode(String.self, forKey: .submitterAgentId),
      summary: try container.decodeIfPresent(String.self, forKey: .summary),
      requiredConsensus:
        try container.decodeIfPresent(Int.self, forKey: .requiredConsensus) ?? 2
    )
  }
}

public struct ReviewerEntry: Codable, Equatable, Sendable {
  public let reviewerAgentId: String
  public let reviewerRuntime: String
  public let claimedAt: String
  public let submittedAt: String?

  public init(
    reviewerAgentId: String,
    reviewerRuntime: String,
    claimedAt: String,
    submittedAt: String? = nil
  ) {
    self.reviewerAgentId = reviewerAgentId
    self.reviewerRuntime = reviewerRuntime
    self.claimedAt = claimedAt
    self.submittedAt = submittedAt
  }
}

public struct ReviewClaim: Codable, Equatable, Sendable {
  public let reviewers: [ReviewerEntry]

  public init(reviewers: [ReviewerEntry] = []) {
    self.reviewers = reviewers
  }

  enum CodingKeys: String, CodingKey { case reviewers }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    self.init(
      reviewers: try container.decodeIfPresent([ReviewerEntry].self, forKey: .reviewers) ?? []
    )
  }
}

public enum ReviewVerdict: String, Codable, CaseIterable, Sendable {
  case approve
  case requestChanges = "request_changes"
  case reject

  init?(rawOrLegacyValue value: String) {
    switch value {
    case "request-changes", "requestChanges":
      self = .requestChanges
    default:
      self.init(rawValue: value)
    }
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.singleValueContainer()
    let value = try container.decode(String.self)
    guard let verdict = Self(rawOrLegacyValue: value) else {
      throw DecodingError.dataCorruptedError(
        in: container,
        debugDescription: "Invalid review verdict: \(value)"
      )
    }
    self = verdict
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.singleValueContainer()
    try container.encode(rawValue)
  }

  public var title: String {
    switch self {
    case .approve:
      "Approve"
    case .requestChanges:
      "Request Changes"
    case .reject:
      "Reject"
    }
  }
}

public enum ReviewPointState: String, Codable, CaseIterable, Sendable {
  case open
  case agreed
  case disputed
  case resolved

  public var title: String {
    switch self {
    case .open:
      "Open"
    case .agreed:
      "Agreed"
    case .disputed:
      "Disputed"
    case .resolved:
      "Resolved"
    }
  }
}

public struct ReviewPoint: Codable, Equatable, Identifiable, Sendable {
  public let pointId: String
  public let text: String
  public let state: ReviewPointState
  public let workerNote: String?

  public var id: String { pointId }

  public init(
    pointId: String,
    text: String,
    state: ReviewPointState = .open,
    workerNote: String? = nil
  ) {
    self.pointId = pointId
    self.text = text
    self.state = state
    self.workerNote = workerNote
  }

  enum CodingKeys: String, CodingKey { case pointId, text, state, workerNote }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    self.init(
      pointId: try container.decode(String.self, forKey: .pointId),
      text: try container.decode(String.self, forKey: .text),
      state: try container.decodeIfPresent(ReviewPointState.self, forKey: .state) ?? .open,
      workerNote: try container.decodeIfPresent(String.self, forKey: .workerNote)
    )
  }
}

public struct Review: Codable, Equatable, Identifiable, Sendable {
  public let reviewId: String
  public let round: Int
  public let reviewerAgentId: String
  public let reviewerRuntime: String
  public let verdict: ReviewVerdict
  public let summary: String
  public let points: [ReviewPoint]
  public let recordedAt: String

  public var id: String { reviewId }

  public init(
    reviewId: String,
    round: Int,
    reviewerAgentId: String,
    reviewerRuntime: String,
    verdict: ReviewVerdict,
    summary: String,
    points: [ReviewPoint] = [],
    recordedAt: String
  ) {
    self.reviewId = reviewId
    self.round = round
    self.reviewerAgentId = reviewerAgentId
    self.reviewerRuntime = reviewerRuntime
    self.verdict = verdict
    self.summary = summary
    self.points = points
    self.recordedAt = recordedAt
  }

  enum CodingKeys: String, CodingKey {
    case reviewId, round, reviewerAgentId, reviewerRuntime
    case verdict, summary, points, recordedAt
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    self.init(
      reviewId: try container.decode(String.self, forKey: .reviewId),
      round: try container.decode(Int.self, forKey: .round),
      reviewerAgentId: try container.decode(String.self, forKey: .reviewerAgentId),
      reviewerRuntime: try container.decode(String.self, forKey: .reviewerRuntime),
      verdict: try container.decode(ReviewVerdict.self, forKey: .verdict),
      summary: try container.decode(String.self, forKey: .summary),
      points: try container.decodeIfPresent([ReviewPoint].self, forKey: .points) ?? [],
      recordedAt: try container.decode(String.self, forKey: .recordedAt)
    )
  }
}

public struct ReviewConsensus: Codable, Equatable, Sendable {
  public let verdict: ReviewVerdict
  public let summary: String
  public let points: [ReviewPoint]
  public let closedAt: String
  public let reviewerAgentIds: [String]

  public init(
    verdict: ReviewVerdict,
    summary: String,
    points: [ReviewPoint] = [],
    closedAt: String,
    reviewerAgentIds: [String] = []
  ) {
    self.verdict = verdict
    self.summary = summary
    self.points = points
    self.closedAt = closedAt
    self.reviewerAgentIds = reviewerAgentIds
  }

  enum CodingKeys: String, CodingKey {
    case verdict, summary, points, closedAt, reviewerAgentIds
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    self.init(
      verdict: try container.decode(ReviewVerdict.self, forKey: .verdict),
      summary: try container.decode(String.self, forKey: .summary),
      points: try container.decodeIfPresent([ReviewPoint].self, forKey: .points) ?? [],
      closedAt: try container.decode(String.self, forKey: .closedAt),
      reviewerAgentIds:
        try container.decodeIfPresent([String].self, forKey: .reviewerAgentIds) ?? []
    )
  }
}

public struct ArbitrationOutcome: Codable, Equatable, Sendable {
  public let arbiterAgentId: String
  public let verdict: ReviewVerdict
  public let summary: String
  public let recordedAt: String

  public init(
    arbiterAgentId: String,
    verdict: ReviewVerdict,
    summary: String,
    recordedAt: String
  ) {
    self.arbiterAgentId = arbiterAgentId
    self.verdict = verdict
    self.summary = summary
    self.recordedAt = recordedAt
  }
}
