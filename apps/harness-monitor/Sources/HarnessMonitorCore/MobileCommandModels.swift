import Foundation

public struct MobileCommandTarget: Codable, Equatable, Sendable {
  public var stationID: String
  public var sessionID: String?
  public var agentID: String?
  public var reviewID: String?
  public var taskID: String?
  public var targetRevision: Int64

  public init(
    stationID: String,
    sessionID: String? = nil,
    agentID: String? = nil,
    reviewID: String? = nil,
    taskID: String? = nil,
    targetRevision: Int64
  ) {
    self.stationID = stationID
    self.sessionID = sessionID
    self.agentID = agentID
    self.reviewID = reviewID
    self.taskID = taskID
    self.targetRevision = targetRevision
  }
}

public struct MobileDeviceDescriptor: Codable, Equatable, Identifiable, Sendable {
  public let id: String
  public var displayName: String
  public var publicKeyFingerprint: String
  public var pairedAt: Date
  public var lastCommandAt: Date?

  public var collectionID: String {
    "\(id)|\(publicKeyFingerprint)"
  }

  public init(
    id: String,
    displayName: String,
    publicKeyFingerprint: String,
    pairedAt: Date,
    lastCommandAt: Date? = nil
  ) {
    self.id = id
    self.displayName = displayName
    self.publicKeyFingerprint = publicKeyFingerprint
    self.pairedAt = pairedAt
    self.lastCommandAt = lastCommandAt
  }
}

public struct MobileCommandRecord: Codable, Equatable, Identifiable, Sendable {
  public let id: String
  public var stationID: String
  public var kind: MobileCommandKind
  public var risk: MobileCommandRisk
  public var status: MobileCommandStatus
  public var title: String
  public var confirmationText: String
  public var auditReason: String?
  public var target: MobileCommandTarget
  public var payload: [String: String]
  public var actorDeviceID: String
  public var createdAt: Date
  public var expiresAt: Date
  public var updatedAt: Date
  public var receipt: MobileCommandReceipt?

  public init(
    id: String,
    stationID: String,
    kind: MobileCommandKind,
    risk: MobileCommandRisk,
    status: MobileCommandStatus,
    title: String,
    confirmationText: String,
    auditReason: String? = nil,
    target: MobileCommandTarget,
    payload: [String: String] = [:],
    actorDeviceID: String,
    createdAt: Date,
    expiresAt: Date,
    updatedAt: Date,
    receipt: MobileCommandReceipt? = nil
  ) {
    self.id = id
    self.stationID = stationID
    self.kind = kind
    self.risk = risk
    self.status = status
    self.title = title
    self.confirmationText = confirmationText
    self.auditReason = auditReason
    self.target = target
    self.payload = payload
    self.actorDeviceID = actorDeviceID
    self.createdAt = createdAt
    self.expiresAt = expiresAt
    self.updatedAt = updatedAt
    self.receipt = receipt
  }
}

public struct MobileCommandReceipt: Codable, Equatable, Sendable {
  public var commandID: String
  public var stationID: String
  public var status: MobileCommandStatus
  public var message: String
  public var receivedAt: Date
  public var completedAt: Date?
  public var executionRevision: Int64

  public init(
    commandID: String,
    stationID: String,
    status: MobileCommandStatus,
    message: String,
    receivedAt: Date,
    completedAt: Date? = nil,
    executionRevision: Int64
  ) {
    self.commandID = commandID
    self.stationID = stationID
    self.status = status
    self.message = message
    self.receivedAt = receivedAt
    self.completedAt = completedAt
    self.executionRevision = executionRevision
  }
}

public struct MobilePairingInvitation: Codable, Equatable, Sendable {
  public var stationID: String
  public var stationName: String
  public var endpoint: URL
  public var publicKeyFingerprint: String
  public var nonce: String
  public var expiresAt: Date

  public init(
    stationID: String,
    stationName: String,
    endpoint: URL,
    publicKeyFingerprint: String,
    nonce: String,
    expiresAt: Date
  ) {
    self.stationID = stationID
    self.stationName = stationName
    self.endpoint = endpoint
    self.publicKeyFingerprint = publicKeyFingerprint
    self.nonce = nonce
    self.expiresAt = expiresAt
  }
}
