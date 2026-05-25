import Foundation
import HarnessMonitorCore

extension MobileMirrorSnapshot {
  func mergingMobileCommandRecords(
    commands: [MobileCommandRecord],
    receipts: [MobileCommandReceipt],
    now: Date
  ) -> Self {
    guard !commands.isEmpty || !receipts.isEmpty else {
      return self
    }
    var merged = self
    var commandsByID = Dictionary(uniqueKeysWithValues: merged.commands.map { ($0.id, $0) })
    var commandOrder = merged.commands.map(\.id)
    for command in commands {
      if commandsByID[command.id] == nil {
        commandOrder.append(command.id)
      }
      commandsByID[command.id] = command.updatingExpiredStatus(now: now)
    }
    for receipt in receipts.sorted(by: oldestReceiptFirst) {
      guard var command = commandsByID[receipt.commandID] else {
        continue
      }
      if command.status.isTerminal, !receipt.status.isTerminal {
        continue
      }
      command.status = receipt.status
      command.receipt = receipt
      command.updatedAt = receipt.completedAt ?? receipt.receivedAt
      commandsByID[receipt.commandID] = command
    }
    merged.commands = commandOrder.compactMap { commandID in
      commandsByID.removeValue(forKey: commandID)
    }
    if !commandsByID.isEmpty {
      merged.commands.append(
        contentsOf: commandsByID.values.sorted { lhs, rhs in
          if lhs.updatedAt != rhs.updatedAt {
            return lhs.updatedAt > rhs.updatedAt
          }
          return lhs.id < rhs.id
        }
      )
    }
    return merged
  }
}

extension MobileCommandRecord {
  func updatingExpiredStatus(now: Date) -> Self {
    guard isExpired(now: now), !status.isTerminal else {
      return self
    }
    var command = self
    command.status = .expired
    command.updatedAt = expiresAt
    return command
  }
}

private func oldestReceiptFirst(
  _ lhs: MobileCommandReceipt,
  _ rhs: MobileCommandReceipt
) -> Bool {
  let lhsDate = lhs.completedAt ?? lhs.receivedAt
  let rhsDate = rhs.completedAt ?? rhs.receivedAt
  if lhsDate != rhsDate {
    return lhsDate < rhsDate
  }
  return lhs.status.rawValue < rhs.status.rawValue
}
