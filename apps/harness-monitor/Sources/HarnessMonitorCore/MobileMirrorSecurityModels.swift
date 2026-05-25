import Foundation

public enum MobileMirrorRecordType: String, Codable, CaseIterable, Sendable {
  case station
  case snapshot
  case snapshotChunk
  case attention
  case session
  case review
  case command
  case receipt
  case event
  case tombstone
}

public struct MobileEncryptedEnvelope: Codable, Equatable, Sendable {
  public var algorithm: String
  public var keyID: String
  public var nonce: Data
  public var ciphertext: Data
  public var tag: Data
  public var additionalAuthenticatedData: Data
  public var createdAt: Date

  public init(
    algorithm: String = "AES.GCM.256",
    keyID: String,
    nonce: Data,
    ciphertext: Data,
    tag: Data,
    additionalAuthenticatedData: Data = Data(),
    createdAt: Date
  ) {
    self.algorithm = algorithm
    self.keyID = keyID
    self.nonce = nonce
    self.ciphertext = ciphertext
    self.tag = tag
    self.additionalAuthenticatedData = additionalAuthenticatedData
    self.createdAt = createdAt
  }
}

public struct MobileMirrorRecordMetadata: Codable, Equatable, Identifiable, Sendable {
  public var id: String
  public var type: MobileMirrorRecordType
  public var stationID: String
  public var schemaVersion: Int
  public var revision: Int64
  public var updatedAt: Date
  public var expiresAt: Date
  public var tombstone: Bool
  public var chunkIDs: [String]

  public init(
    id: String,
    type: MobileMirrorRecordType,
    stationID: String,
    schemaVersion: Int = 1,
    revision: Int64,
    updatedAt: Date,
    expiresAt: Date,
    tombstone: Bool = false,
    chunkIDs: [String] = []
  ) {
    self.id = id
    self.type = type
    self.stationID = stationID
    self.schemaVersion = schemaVersion
    self.revision = revision
    self.updatedAt = updatedAt
    self.expiresAt = expiresAt
    self.tombstone = tombstone
    self.chunkIDs = chunkIDs
  }
}

public struct MobileMirrorRecord: Codable, Equatable, Identifiable, Sendable {
  public var metadata: MobileMirrorRecordMetadata
  public var envelope: MobileEncryptedEnvelope?

  public var id: String { metadata.id }

  public init(metadata: MobileMirrorRecordMetadata, envelope: MobileEncryptedEnvelope?) {
    self.metadata = metadata
    self.envelope = envelope
  }
}

public struct MobileSignedCommand: Codable, Equatable, Identifiable, Sendable {
  public var command: MobileCommandRecord
  public var signature: Data
  public var signingKeyFingerprint: String
  public var signedAt: Date

  public var id: String { command.id }

  public init(
    command: MobileCommandRecord,
    signature: Data,
    signingKeyFingerprint: String,
    signedAt: Date
  ) {
    self.command = command
    self.signature = signature
    self.signingKeyFingerprint = signingKeyFingerprint
    self.signedAt = signedAt
  }
}

public enum MobileCommandValidationError: Error, Equatable, Sendable {
  case emptyCommandID
  case emptyStationID
  case targetStationMismatch(expected: String, actual: String)
  case missingTitle
  case missingConfirmationText
  case invalidLifetime(createdAt: Date, expiresAt: Date)
  case expired
  case terminalStatus
  case staleRevision(expected: Int64, actual: Int64)
  case destructiveCommandMissingAuditReason
}

extension MobileCommandRecord {
  public func isExpired(now: Date) -> Bool {
    expiresAt <= now
  }

  public func validatingForQueue(now: Date) throws -> Self {
    let commandID = id.trimmingCharacters(in: .whitespacesAndNewlines)
    if commandID.isEmpty {
      throw MobileCommandValidationError.emptyCommandID
    }
    let normalizedStationID = stationID.trimmingCharacters(in: .whitespacesAndNewlines)
    if normalizedStationID.isEmpty {
      throw MobileCommandValidationError.emptyStationID
    }
    let targetStationID = target.stationID.trimmingCharacters(in: .whitespacesAndNewlines)
    guard targetStationID == normalizedStationID else {
      throw MobileCommandValidationError.targetStationMismatch(
        expected: normalizedStationID,
        actual: targetStationID
      )
    }
    if title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
      throw MobileCommandValidationError.missingTitle
    }
    if confirmationText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
      throw MobileCommandValidationError.missingConfirmationText
    }
    if createdAt >= expiresAt {
      throw MobileCommandValidationError.invalidLifetime(
        createdAt: createdAt,
        expiresAt: expiresAt
      )
    }
    if isExpired(now: now) {
      throw MobileCommandValidationError.expired
    }
    if status.isTerminal {
      throw MobileCommandValidationError.terminalStatus
    }
    if risk == .destructive,
      auditReason?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true
    {
      throw MobileCommandValidationError.destructiveCommandMissingAuditReason
    }
    return self
  }

  public func validatingFreshState(currentRevision: Int64) throws -> Self {
    guard risk.requiresFreshState else {
      return self
    }
    guard target.targetRevision == currentRevision else {
      throw MobileCommandValidationError.staleRevision(
        expected: target.targetRevision,
        actual: currentRevision
      )
    }
    return self
  }
}

extension MobileMirrorSnapshot {
  public func station(id: String) -> MobileStationSummary? {
    stations.first { $0.id == id }
  }

  public func commands(for stationID: String) -> [MobileCommandRecord] {
    commands
      .filter { $0.stationID == stationID }
      .sorted { $0.updatedAt > $1.updatedAt }
  }
}
