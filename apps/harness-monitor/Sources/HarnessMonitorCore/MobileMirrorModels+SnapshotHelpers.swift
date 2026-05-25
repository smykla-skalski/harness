import Foundation

struct ExistingAttentionCoverage {
  var reviewIDs: Set<String> = []
  var taskIDs: Set<String> = []
  var agentIDs: Set<String> = []
  var sessionIDs: Set<String> = []
  var commandIDs: Set<String> = []
  var stationHealthIDs: Set<String> = []

  init(attention: [MobileAttentionItem]) {
    for item in attention {
      insertIfPresent(item.target?.reviewID, into: &reviewIDs)
      insertIfPresent(item.commandPayload["pullRequestID"], into: &reviewIDs)
      insertIfPresent(item.target?.taskID, into: &taskIDs)
      insertIfPresent(item.commandPayload["itemID"], into: &taskIDs)
      insertIfPresent(item.target?.agentID, into: &agentIDs)
      insertIfPresent(item.target?.sessionID, into: &sessionIDs)
      insertIfPresent(item.commandPayload["commandID"], into: &commandIDs)
      if item.kind == .stationHealth {
        stationHealthIDs.insert(item.stationID)
      }
    }
  }

  private func insertIfPresent(_ value: String?, into values: inout Set<String>) {
    guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
      !trimmed.isEmpty
    else {
      return
    }
    values.insert(trimmed)
  }
}

extension Array where Element == MobileDeviceDescriptor {
  func mergingTrustedDevices(_ incoming: [MobileDeviceDescriptor]) -> Self {
    var devicesByID: [String: MobileDeviceDescriptor] = [:]
    var orderedIDs: [String] = []
    for device in self {
      let id = device.collectionID
      if devicesByID[id] == nil {
        orderedIDs.append(id)
      }
      devicesByID[id] = device
    }
    for device in incoming {
      let id = device.collectionID
      if devicesByID[id] == nil {
        orderedIDs.append(id)
      }
      devicesByID[id] = device
    }
    return orderedIDs.compactMap { devicesByID[$0] }
  }
}
