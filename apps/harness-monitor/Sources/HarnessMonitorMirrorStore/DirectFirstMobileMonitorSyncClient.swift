import Foundation
import HarnessMonitorCloudMirror
import HarnessMonitorCore

public struct DirectFirstMobileMonitorSyncClient: MobileMonitorSyncClient, Sendable {
  private let direct: any MobileMonitorSyncClient
  private let cloudFallback: any MobileMonitorSyncClient

  public init(
    direct: any MobileMonitorSyncClient,
    cloudFallback: any MobileMonitorSyncClient
  ) {
    self.direct = direct
    self.cloudFallback = cloudFallback
  }

  public var supportsCommands: Bool {
    false
  }

  public func fetchLatestSnapshot(
    stationID: String,
    now: Date
  ) async throws -> MobileMirrorSnapshot? {
    do {
      return try await direct.fetchLatestSnapshot(stationID: stationID, now: now)
    } catch {
      guard Self.allowsCloudFallback(error) else {
        throw error
      }
      return try await cloudFallback.fetchLatestSnapshot(stationID: stationID, now: now)
    }
  }

  public func queueCommand(
    _ command: MobileCommandRecord,
    currentRevision: Int64,
    now: Date
  ) async throws -> MobileQueuedCommand {
    throw MobileRemoteDaemonSyncError.commandsUnavailable
  }

  public func cancelCommand(
    _ command: MobileCommandRecord,
    currentRevision: Int64,
    now: Date
  ) async throws -> MobileCommandReceipt {
    throw MobileRemoteDaemonSyncError.commandsUnavailable
  }

  private static func allowsCloudFallback(_ error: any Error) -> Bool {
    if error is URLError {
      return true
    }
    return (error as? MobileRemoteDaemonSyncError)?.allowsCloudFallback == true
  }
}
