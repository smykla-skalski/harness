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

public actor MobileMacRelayService {
  private let stationID: String
  private let snapshotSource: any MobileMirrorSnapshotSource
  private let commandQueue: any MobileRelayCommandQueue
  private let executor: any MobileRelayCommandExecutor
  private var executedCommandIDs: Set<String> = []

  public init(
    stationID: String,
    snapshotSource: any MobileMirrorSnapshotSource,
    commandQueue: any MobileRelayCommandQueue,
    executor: any MobileRelayCommandExecutor
  ) {
    self.stationID = stationID
    self.snapshotSource = snapshotSource
    self.commandQueue = commandQueue
    self.executor = executor
  }

  @discardableResult
  public func executePendingCommands(now: Date = .now) async throws -> [MobileCommandReceipt] {
    let snapshot = try await snapshotSource.makeSnapshot(now: now)
    let pendingCommands = try await commandQueue.pendingCommands(stationID: stationID)
    var receipts: [MobileCommandReceipt] = []

    for command in pendingCommands where !executedCommandIDs.contains(command.id) {
      let receipt: MobileCommandReceipt
      do {
        _ =
          try command
          .validatingForQueue(now: now)
          .validatingFreshState(currentRevision: snapshot.revision)
        receipt = try await executor.execute(command, snapshot: snapshot)
      } catch MobileCommandValidationError.expired {
        receipt = Self.receipt(
          for: command,
          status: .expired,
          message: "Command expired before this Mac accepted it.",
          now: now,
          revision: snapshot.revision
        )
      } catch MobileCommandValidationError.staleRevision(let expected, let actual) {
        receipt = Self.receipt(
          for: command,
          status: .failed,
          message:
            "Fresh-state validation rejected revision \(expected); current revision is \(actual).",
          now: now,
          revision: snapshot.revision
        )
      } catch {
        receipt = Self.receipt(
          for: command,
          status: .failed,
          message: String(describing: error),
          now: now,
          revision: snapshot.revision
        )
      }

      executedCommandIDs.insert(command.id)
      try await commandQueue.recordReceipt(receipt, for: command.id)
      receipts.append(receipt)
    }

    return receipts
  }

  private static func receipt(
    for command: MobileCommandRecord,
    status: MobileCommandStatus,
    message: String,
    now: Date,
    revision: Int64
  ) -> MobileCommandReceipt {
    MobileCommandReceipt(
      commandID: command.id,
      stationID: command.stationID,
      status: status,
      message: message,
      receivedAt: now,
      completedAt: now,
      executionRevision: revision
    )
  }
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
