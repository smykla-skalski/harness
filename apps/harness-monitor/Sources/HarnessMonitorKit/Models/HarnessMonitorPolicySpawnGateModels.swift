import Foundation

public struct PolicyCanvasSetSpawnRequiresLivePolicyRequest: Codable, Equatable, Sendable {
  public let enabled: Bool

  public init(enabled: Bool) {
    self.enabled = enabled
  }
}

public struct PolicyCanvasSetSpawnKillSwitchRequest: Codable, Equatable, Sendable {
  public let enabled: Bool

  public init(enabled: Bool) {
    self.enabled = enabled
  }
}

public struct PolicyApprovalGrantsListResponse: Codable, Equatable, Sendable {
  public let grants: [PolicyApprovalGrant]

  public init(grants: [PolicyApprovalGrant]) {
    self.grants = grants
  }
}

public struct PolicyApprovalGrantResolveRequest: Codable, Equatable, Sendable {
  public let grantId: String
  public let approve: Bool
  public let actor: String?

  public init(grantId: String, approve: Bool, actor: String? = nil) {
    self.grantId = grantId
    self.approve = approve
    self.actor = actor
  }
}

public struct PolicyApprovalGrantResolveResponse: Codable, Equatable, Sendable {
  public let grant: PolicyApprovalGrant

  public init(grant: PolicyApprovalGrant) {
    self.grant = grant
  }
}
