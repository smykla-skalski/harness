import Foundation
import HarnessMonitorCloudMirror
import HarnessMonitorCore
import HarnessMonitorCrypto

public enum MobileCommandSubmissionDisposition: Equatable, Sendable {
  case queued
  case completed
}

public struct MobileCommandSubmission: Equatable, Sendable {
  public var command: MobileCommandRecord
  public var disposition: MobileCommandSubmissionDisposition

  public init(
    command: MobileCommandRecord,
    disposition: MobileCommandSubmissionDisposition = .queued
  ) {
    self.command = command
    self.disposition = disposition
  }
}

/// The mobile sync operations the shared store depends on. Tests inject fakes;
/// live credentials select direct remote access, CloudMirror, or both.
public protocol MobileMonitorSyncClient: Sendable {
  var supportsCommands: Bool { get }
  func fetchLatestSnapshot(stationID: String, now: Date) async throws -> MobileMirrorSnapshot?
  func queueCommand(
    _ command: MobileCommandRecord,
    currentRevision: Int64,
    now: Date
  ) async throws -> MobileCommandSubmission
  func cancelCommand(
    _ command: MobileCommandRecord,
    currentRevision: Int64,
    now: Date
  ) async throws -> MobileCommandReceipt
}

extension MobileMonitorSyncClient {
  public var supportsCommands: Bool { false }
}

public protocol MobileMonitorSyncClientFactory: Sendable {
  func makeSyncClient(
    credential: MobilePairedStationCredential,
    identity: MobileDeviceIdentity
  ) -> any MobileMonitorSyncClient
}

/// Builds live direct and CloudMirror sync clients. The optional `actorDeviceID`
/// transform lets the watch stamp relay commands with its own actor id.
public struct LiveMobileMonitorSyncClientFactory: MobileMonitorSyncClientFactory {
  public typealias RemoteSessionFactory =
    @Sendable (MobileRemoteDaemonSPKIPin) -> URLSession

  private let actorDeviceID: @Sendable (MobileDeviceIdentity) -> String?
  private let remoteSessionFactory: RemoteSessionFactory

  public init(
    actorDeviceID: @escaping @Sendable (MobileDeviceIdentity) -> String? = { _ in nil },
    remoteSessionFactory: RemoteSessionFactory? = nil
  ) {
    self.actorDeviceID = actorDeviceID
    self.remoteSessionFactory = remoteSessionFactory ?? Self.defaultRemoteSession
  }

  public func makeSyncClient(
    credential: MobilePairedStationCredential,
    identity: MobileDeviceIdentity
  ) -> any MobileMonitorSyncClient {
    let cloud = makeCloudClient(credential: credential, identity: identity)
    let direct = makeDirectClient(credential: credential)
    switch (direct, cloud) {
    case (.some(let direct), .some(let cloud)):
      return DirectFirstMobileMonitorSyncClient(direct: direct, cloudFallback: cloud)
    case (.some(let direct), .none):
      return direct
    case (.none, .some(let cloud)):
      return cloud
    case (.none, .none):
      return UnavailableMobileMonitorSyncClient()
    }
  }

  private func makeCloudClient(
    credential: MobilePairedStationCredential,
    identity: MobileDeviceIdentity
  ) -> CloudMirrorMobileMonitorSyncClient? {
    guard credential.hasCloudMirrorAccess else {
      return nil
    }
    return CloudMirrorMobileMonitorSyncClient(
      client: MobileCloudMirrorSyncClient(
        database: LiveMobileCloudMirrorDatabase(),
        cipher: MobilePayloadCipher(rawKey: credential.symmetricKeyRawRepresentation),
        deviceIdentity: identity,
        actorDeviceID: actorDeviceID(identity),
        commandKeyID: credential.commandKeyID
      )
    )
  }

  private func makeDirectClient(
    credential: MobilePairedStationCredential
  ) -> MobileRemoteDaemonSyncClient? {
    guard let access = credential.remoteDaemonAccess, access.canRead else {
      return nil
    }
    return MobileRemoteDaemonSyncClient(
      access: access,
      stationID: credential.stationID,
      stationName: credential.stationName,
      defaultStation: credential.defaultStation,
      session: remoteSessionFactory(access.serverSPKISHA256)
    )
  }

  private static func defaultRemoteSession(pin: MobileRemoteDaemonSPKIPin) -> URLSession {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.waitsForConnectivity = true
    configuration.timeoutIntervalForRequest = 15
    configuration.timeoutIntervalForResource = 30
    return MobileRemoteDaemonURLSessionFactory.make(configuration: configuration, pin: pin)
  }
}

private struct UnavailableMobileMonitorSyncClient: MobileMonitorSyncClient {
  var supportsCommands: Bool { false }

  func fetchLatestSnapshot(stationID: String, now: Date) async throws -> MobileMirrorSnapshot? {
    nil
  }

  func queueCommand(
    _ command: MobileCommandRecord,
    currentRevision: Int64,
    now: Date
  ) async throws -> MobileCommandSubmission {
    throw MobileRemoteDaemonSyncError.commandsUnavailable
  }

  func cancelCommand(
    _ command: MobileCommandRecord,
    currentRevision: Int64,
    now: Date
  ) async throws -> MobileCommandReceipt {
    throw MobileRemoteDaemonSyncError.commandsUnavailable
  }
}

private struct CloudMirrorMobileMonitorSyncClient: MobileMonitorSyncClient {
  let client: MobileCloudMirrorSyncClient
  let supportsCommands = true

  func fetchLatestSnapshot(
    stationID: String,
    now: Date
  ) async throws -> MobileMirrorSnapshot? {
    try await client.fetchLatestSnapshot(stationID: stationID, now: now)
  }

  func queueCommand(
    _ command: MobileCommandRecord,
    currentRevision: Int64,
    now: Date
  ) async throws -> MobileCommandSubmission {
    let queued = try await client.queueCommand(
      command,
      currentRevision: currentRevision,
      now: now
    )
    return MobileCommandSubmission(command: queued.signedCommand.command)
  }

  func cancelCommand(
    _ command: MobileCommandRecord,
    currentRevision: Int64,
    now: Date
  ) async throws -> MobileCommandReceipt {
    try await client.cancelCommand(command, currentRevision: currentRevision, now: now)
  }
}
