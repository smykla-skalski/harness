import Foundation
import HarnessMonitorCloudMirror
import HarnessMonitorCore

public protocol MobileMirrorSnapshotSource: Sendable {
  func makeSnapshot(now: Date) async throws -> MobileMirrorSnapshot
}

public protocol MobileRelayCommandQueue: Sendable {
  func pendingCommands(stationID: String) async throws -> [MobileCommandRecord]
  func recordReceipt(_ receipt: MobileCommandReceipt, for commandID: String) async throws
}

public protocol MobileRelayCommandExecutor: Sendable {
  func execute(_ command: MobileCommandRecord, snapshot: MobileMirrorSnapshot) async throws
    -> MobileCommandReceipt
}

public protocol MobileMirrorSnapshotSink: Sendable {
  func writeSnapshot(_ snapshot: MobileMirrorSnapshot) async throws
}

public actor MobileMacRelayService {
  private let stationID: String
  private let snapshotSource: any MobileMirrorSnapshotSource
  private let snapshotSink: (any MobileMirrorSnapshotSink)?
  private let commandQueue: any MobileRelayCommandQueue
  private let executor: any MobileRelayCommandExecutor
  private let secretRedactor = MobileMirrorSecretRedactor()
  private var executedCommandIDs: Set<String> = []

  public init(
    stationID: String,
    snapshotSource: any MobileMirrorSnapshotSource,
    snapshotSink: (any MobileMirrorSnapshotSink)? = nil,
    commandQueue: any MobileRelayCommandQueue,
    executor: any MobileRelayCommandExecutor
  ) {
    self.stationID = stationID
    self.snapshotSource = snapshotSource
    self.snapshotSink = snapshotSink
    self.commandQueue = commandQueue
    self.executor = executor
  }

  @discardableResult
  public func publishSnapshot(now: Date = .now) async throws -> MobileMirrorSnapshot {
    let preparedSnapshot = try await makeMirroredSnapshot(now: now)
    try await snapshotSink?.writeSnapshot(preparedSnapshot.mirroredSnapshot)
    return preparedSnapshot.mirroredSnapshot
  }

  @discardableResult
  public func executePendingCommands(now: Date = .now) async throws -> [MobileCommandReceipt] {
    let preparedSnapshot = try await makeMirroredSnapshot(now: now)
    do {
      try await snapshotSink?.writeSnapshot(preparedSnapshot.mirroredSnapshot)
    } catch MobileCloudMirrorCloudKitError.schemaUnavailable {
      return []
    }
    var terminalReceipts: [MobileCommandReceipt] = []

    for command in preparedSnapshot.pendingCommands where !executedCommandIDs.contains(command.id) {
      let receipt: MobileCommandReceipt
      do {
        _ =
          try command
          .validatingForQueue(now: now)
          .validatingFreshState(currentRevision: preparedSnapshot.sourceSnapshot.revision)
        let acceptedReceipt = Self.receipt(
          for: command,
          status: .accepted,
          message: "Command accepted by this Mac.",
          now: now,
          revision: preparedSnapshot.sourceSnapshot.revision
        )
        try await commandQueue.recordReceipt(acceptedReceipt, for: command.id)
        let runningReceipt = Self.receipt(
          for: command,
          status: .running,
          message: "Command is running on this Mac.",
          now: now,
          revision: preparedSnapshot.sourceSnapshot.revision
        )
        try await commandQueue.recordReceipt(runningReceipt, for: command.id)
        receipt =
          try await executor
          .execute(command, snapshot: preparedSnapshot.sourceSnapshot)
          .redactingMobileMirrorSecrets(using: secretRedactor)
      } catch MobileCommandValidationError.expired {
        receipt = Self.receipt(
          for: command,
          status: .expired,
          message: "Command expired before this Mac accepted it.",
          now: now,
          revision: preparedSnapshot.sourceSnapshot.revision
        )
      } catch MobileCommandValidationError.staleRevision(let expected, let actual) {
        receipt = Self.receipt(
          for: command,
          status: .failed,
          message:
            "Fresh-state validation rejected revision \(expected); current revision is \(actual).",
          now: now,
          revision: preparedSnapshot.sourceSnapshot.revision
        )
      } catch {
        receipt = Self.receipt(
          for: command,
          status: .failed,
          message: redacted(String(describing: error)),
          now: now,
          revision: preparedSnapshot.sourceSnapshot.revision
        )
      }

      executedCommandIDs.insert(command.id)
      try await commandQueue.recordReceipt(receipt, for: command.id)
      terminalReceipts.append(receipt)
    }

    return terminalReceipts
  }

  private func makeMirroredSnapshot(now: Date) async throws -> MobileRelayPreparedSnapshot {
    let snapshot = try await snapshotSource.makeSnapshot(now: now)
    let pendingCommands = try await commandQueue.pendingCommands(stationID: stationID)
    var mirroredSnapshot = snapshot
    mirroredSnapshot.commands = pendingCommands.map {
      $0.redactingMobileMirrorSecrets(using: secretRedactor)
    }
    mirroredSnapshot.stations = snapshot.stations.map { station in
      guard station.id == stationID else {
        return station
      }
      var updatedStation = station
      updatedStation.commandQueueCount = pendingCommands.count
      return updatedStation
    }
    return MobileRelayPreparedSnapshot(
      sourceSnapshot: snapshot,
      mirroredSnapshot: mirroredSnapshot,
      pendingCommands: pendingCommands
    )
  }

  private static func receipt(
    for command: MobileCommandRecord,
    status: MobileCommandStatus,
    message: String,
    now: Date,
    completedAt: Date? = nil,
    revision: Int64
  ) -> MobileCommandReceipt {
    MobileCommandReceipt(
      commandID: command.id,
      stationID: command.stationID,
      status: status,
      message: message,
      receivedAt: now,
      completedAt: status.isTerminal ? (completedAt ?? now) : completedAt,
      executionRevision: revision
    )
  }

  private func redacted(_ value: String) -> String {
    secretRedactor.redact(value)
  }
}

private struct MobileRelayPreparedSnapshot: Sendable {
  var sourceSnapshot: MobileMirrorSnapshot
  var mirroredSnapshot: MobileMirrorSnapshot
  var pendingCommands: [MobileCommandRecord]
}

public struct DemoMobileMirrorSnapshotSource: MobileMirrorSnapshotSource {
  public init() {}

  public func makeSnapshot(now: Date) async throws -> MobileMirrorSnapshot {
    MobileDemoFixtures.snapshot(now: now)
  }
}

public actor InMemoryMobileRelayCommandQueue: MobileRelayCommandQueue {
  private var commands: [MobileCommandRecord]
  private(set) public var receipts: [MobileCommandReceipt] = []

  public init(commands: [MobileCommandRecord]) {
    self.commands = commands
  }

  public func pendingCommands(stationID: String) async throws -> [MobileCommandRecord] {
    commands.filter {
      $0.stationID == stationID
        && !$0.status.isTerminal
        && $0.status != .draft
    }
  }

  public func recordReceipt(_ receipt: MobileCommandReceipt, for commandID: String) async throws {
    receipts.append(receipt)
    guard let index = commands.firstIndex(where: { $0.id == commandID }) else {
      return
    }
    commands[index].status = receipt.status
    commands[index].receipt = receipt
    commands[index].updatedAt = receipt.completedAt ?? receipt.receivedAt
  }
}

public struct EchoMobileRelayCommandExecutor: MobileRelayCommandExecutor {
  public init() {}

  public func execute(
    _ command: MobileCommandRecord,
    snapshot: MobileMirrorSnapshot
  ) async throws -> MobileCommandReceipt {
    MobileCommandReceipt(
      commandID: command.id,
      stationID: command.stationID,
      status: .succeeded,
      message:
        "\(command.kind.title) accepted by \(snapshot.station(id: command.stationID)?.displayName ?? "Mac").",
      receivedAt: .now,
      completedAt: .now,
      executionRevision: snapshot.revision
    )
  }
}
