import Foundation
import HarnessMonitorCloudMirror
import HarnessMonitorCore

public actor MobileCloudMirrorRelayCommandQueue: MobileRelayCommandQueue {
  private let commandQueue: MobileCloudMirrorCommandQueue
  private let receiptKeyID: String
  private let now: @Sendable () -> Date

  public init(
    commandQueue: MobileCloudMirrorCommandQueue,
    receiptKeyID: String,
    now: @escaping @Sendable () -> Date = Date.init
  ) {
    self.commandQueue = commandQueue
    self.receiptKeyID = receiptKeyID
    self.now = now
  }

  public func pendingCommands(stationID: String) async throws -> [MobileCommandRecord] {
    try await commandQueue.pendingCommands(stationID: stationID, now: now())
  }

  public func recordReceipt(_ receipt: MobileCommandReceipt, for commandID: String) async throws {
    _ = try await commandQueue.recordReceipt(receipt, keyID: receiptKeyID, now: now())
  }
}
