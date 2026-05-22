import Foundation

public struct ReviewsCapabilitiesResponse: Codable, Equatable, Sendable {
  public let schemaVersion: UInt32
  public let supportsActionPreview: Bool
  public let supportsCheckRunLinks: Bool
  public let supportsRepositorySyncHealth: Bool
  public let supportsPersistentActionDiagnostics: Bool

  public init(
    schemaVersion: UInt32 = 1,
    supportsActionPreview: Bool = true,
    supportsCheckRunLinks: Bool = true,
    supportsRepositorySyncHealth: Bool = true,
    supportsPersistentActionDiagnostics: Bool = true
  ) {
    self.schemaVersion = schemaVersion
    self.supportsActionPreview = supportsActionPreview
    self.supportsCheckRunLinks = supportsCheckRunLinks
    self.supportsRepositorySyncHealth = supportsRepositorySyncHealth
    self.supportsPersistentActionDiagnostics = supportsPersistentActionDiagnostics
  }

  public static let fallback = Self(
    schemaVersion: 0,
    supportsActionPreview: false,
    supportsCheckRunLinks: false,
    supportsRepositorySyncHealth: false,
    supportsPersistentActionDiagnostics: false
  )
}

public enum ReviewActionPreviewKind: TaskBoardOpenEnum, CaseIterable, Identifiable {
  case approve
  case merge
  case rerunChecks
  case addLabel
  case auto
  case unknown(String)

  public static let allCases: [Self] = [.approve, .merge, .rerunChecks, .addLabel, .auto]
  public var id: String { rawValue }

  public var rawValue: String {
    switch self {
    case .approve: "approve"
    case .merge: "merge"
    case .rerunChecks: "rerun_checks"
    case .addLabel: "add_label"
    case .auto: "auto"
    case .unknown(let raw): raw
    }
  }

  public init(rawValue: String) {
    switch rawValue {
    case "approve": self = .approve
    case "merge": self = .merge
    case "rerun_checks": self = .rerunChecks
    case "add_label": self = .addLabel
    case "auto": self = .auto
    default: self = .unknown(rawValue)
    }
  }
}

public struct ReviewsActionPreviewRequest: Codable, Equatable, Sendable {
  public let action: ReviewActionPreviewKind
  public let targets: [ReviewTarget]
  public let method: TaskBoardGitHubMergeMethod

  public init(
    action: ReviewActionPreviewKind,
    targets: [ReviewTarget],
    method: TaskBoardGitHubMergeMethod = .squash
  ) {
    self.action = action
    self.targets = targets
    self.method = method
  }
}

public struct ReviewsActionPreviewResponse: Codable, Equatable, Sendable {
  public let action: ReviewActionPreviewKind
  public let capabilities: ReviewsCapabilitiesResponse
  public let totalCount: Int
  public let actionableCount: Int
  public let skippedCount: Int
  public let warnings: [String]
  public let targets: [ReviewActionPreviewTarget]

  public init(
    action: ReviewActionPreviewKind,
    capabilities: ReviewsCapabilitiesResponse = .fallback,
    totalCount: Int,
    actionableCount: Int,
    skippedCount: Int,
    warnings: [String] = [],
    targets: [ReviewActionPreviewTarget] = []
  ) {
    self.action = action
    self.capabilities = capabilities
    self.totalCount = totalCount
    self.actionableCount = actionableCount
    self.skippedCount = skippedCount
    self.warnings = warnings
    self.targets = targets
  }
}

public struct ReviewActionPreviewTarget: Codable, Equatable, Sendable {
  public let pullRequestID: String
  public let repository: String
  public let number: UInt64
  public let eligible: Bool
  public let reason: String?
  public let warnings: [String]

  public init(
    pullRequestID: String,
    repository: String,
    number: UInt64,
    eligible: Bool,
    reason: String? = nil,
    warnings: [String] = []
  ) {
    self.pullRequestID = pullRequestID
    self.repository = repository
    self.number = number
    self.eligible = eligible
    self.reason = reason
    self.warnings = warnings
  }

  enum CodingKeys: String, CodingKey {
    case pullRequestID = "pullRequestId"
    case repository
    case number
    case eligible
    case reason
    case warnings
  }
}
