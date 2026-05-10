import Foundation
import SwiftData

extension DecisionStore {
  nonisolated func fetchDecision(id: String, context: ModelContext) throws -> Decision? {
    var descriptor = FetchDescriptor<Decision>(
      predicate: #Predicate<Decision> { $0.id == id }
    )
    descriptor.fetchLimit = 1
    return try context.fetch(descriptor).first
  }

  nonisolated func isOpen(_ decision: Decision, now: Date) -> Bool {
    guard decision.statusRaw == Status.open || decision.statusRaw == Status.snoozed else {
      return false
    }
    if decision.statusRaw == Status.snoozed {
      guard let until = decision.snoozedUntil else { return true }
      return until <= now
    }
    return true
  }

  nonisolated func isUnresolved(_ decision: Decision) -> Bool {
    decision.statusRaw == Status.open || decision.statusRaw == Status.snoozed
  }

  nonisolated func shouldReopen(_ decision: Decision, now: Date) -> Bool {
    if decision.statusRaw == Status.dismissed {
      return true
    }
    guard decision.statusRaw == Status.snoozed else {
      return false
    }
    guard let snoozedUntil = decision.snoozedUntil else {
      return true
    }
    return snoozedUntil <= now
  }

  nonisolated func hasTerminalResolutionOutcome(_ decision: Decision) -> Bool {
    guard let resolutionJSON = decision.resolutionJSON,
      let data = resolutionJSON.data(using: .utf8),
      let outcome = try? JSONDecoder().decode(DecisionOutcome.self, from: data)
    else {
      return false
    }
    return isTerminalResolutionOutcome(outcome)
  }

  nonisolated func isTerminalResolutionOutcome(_ outcome: DecisionOutcome) -> Bool {
    outcome.note == "client_deadline_exceeded" || outcome.note == "daemon_shutdown"
  }

  func encodeOutcome(_ outcome: DecisionOutcome) throws -> String {
    let data = try Self.outcomeEncoder.encode(outcome)
    guard let string = String(bytes: data, encoding: .utf8) else {
      throw EncodingError.invalidValue(
        outcome,
        .init(codingPath: [], debugDescription: "DecisionOutcome JSON was not valid UTF-8")
      )
    }
    return string
  }

  func yield(_ event: DecisionEvent) {
    eventsContinuation.yield(event)
  }

  nonisolated func withReadContext<T>(_ operation: (ModelContext) throws -> T) throws -> T {
    try readContextLock.withLock { _ in
      let context = ModelContext(container)
      return try operation(context)
    }
  }

  func withMutationContext<T>(_ operation: (ModelContext) throws -> T) throws -> T {
    let context = ModelContext(container)
    context.autosaveEnabled = false
    let result = try operation(context)
    if context.hasChanges {
      try context.save()
    }
    return result
  }
}
