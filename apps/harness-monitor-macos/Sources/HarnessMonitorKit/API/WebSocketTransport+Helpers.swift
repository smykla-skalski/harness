import Foundation

final class SemanticBatchDeliveryTracker: @unchecked Sendable {
  var delivered = false
}

struct PendingAcpEventPushKey: Hashable, Sendable {
  let sessionId: String
  let acpId: String
}

struct BufferedAcpEvent: Sendable {
  let event: AcpConversationEvent
  let rawWeight: Int
}

struct PendingAcpEventPushBatch: Sendable {
  let sessionId: String
  let acpId: String
  var recordedAt: String
  var rawCount: Int
  var droppedRawCount: Int
  private var bufferedEvents: [BufferedAcpEvent]

  init(recordedAt: String, payload: AcpEventBatchPayload, maxRetainedEvents: Int) {
    sessionId = payload.sessionId
    acpId = payload.acpId
    self.recordedAt = recordedAt
    rawCount = payload.rawCount
    droppedRawCount = 0
    bufferedEvents = Self.weightedEvents(from: payload)
    trim(to: maxRetainedEvents)
  }

  var payload: AcpEventBatchPayload {
    AcpEventBatchPayload(
      acpId: acpId,
      sessionId: sessionId,
      rawCount: rawCount,
      events: bufferedEvents.map(\.event)
    )
  }

  mutating func merge(
    recordedAt: String,
    payload: AcpEventBatchPayload,
    maxRetainedEvents: Int
  ) {
    self.recordedAt = recordedAt
    rawCount += payload.rawCount
    bufferedEvents.append(contentsOf: Self.weightedEvents(from: payload))
    trim(to: maxRetainedEvents)
  }

  private mutating func trim(to maxRetainedEvents: Int) {
    let overflowCount = bufferedEvents.count - maxRetainedEvents
    guard overflowCount > 0 else {
      return
    }
    droppedRawCount += bufferedEvents.prefix(overflowCount).reduce(0) { partialResult, event in
      partialResult + event.rawWeight
    }
    bufferedEvents.removeFirst(overflowCount)
  }

  private static func weightedEvents(from payload: AcpEventBatchPayload) -> [BufferedAcpEvent] {
    guard !payload.events.isEmpty else {
      return []
    }
    let baseWeight = payload.rawCount / payload.events.count
    let remainder = payload.rawCount % payload.events.count
    return payload.events.enumerated().map { index, event in
      BufferedAcpEvent(
        event: event,
        rawWeight: payload.rawCount > 0 ? baseWeight + (index < remainder ? 1 : 0) : 0
      )
    }
  }
}
