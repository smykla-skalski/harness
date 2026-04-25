import Foundation
import OpenTelemetryApi
import os

public final class HarnessMonitorSignpostBridge: @unchecked Sendable {
  private let signposter: OSSignposter
  private let lock = NSLock()
  private var activeIntervals: [ObjectIdentifier: any Span] = [:]

  public init(
    subsystem: String = "io.harnessmonitor",
    category: String = "perf"
  ) {
    self.signposter = OSSignposter(subsystem: subsystem, category: category)
  }

  public func beginInterval(name: StaticString) -> (OSSignpostIntervalState, any Span) {
    let state = signposter.beginInterval(name, id: .exclusive)
    let nameString = "\(name)"
    let span = HarnessMonitorTelemetry.shared.startSpan(
      name: "perf.\(nameString)",
      kind: .internal,
      attributes: ["perf.signpost.name": .string(nameString)]
    )
    let key = ObjectIdentifier(state as AnyObject)
    lock.withLock {
      activeIntervals[key] = span
    }
    return (state, span)
  }

  public func endInterval(name: StaticString, state: OSSignpostIntervalState) {
    signposter.endInterval(name, state)
    let key = ObjectIdentifier(state as AnyObject)
    let span = lock.withLock {
      activeIntervals.removeValue(forKey: key)
    }
    span?.end()
  }

  @MainActor
  public func withInterval<T>(
    name: StaticString,
    flushOnCompletion: Bool = false,
    _ operation: @MainActor () async throws -> T
  ) async rethrows -> T {
    let (state, _) = beginInterval(name: name)
    defer {
      if flushOnCompletion {
        HarnessMonitorTelemetry.shared.forceFlush()
      }
    }
    defer { endInterval(name: name, state: state) }
    return try await operation()
  }
}
