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
    lock.withLock {
      _ = activeIntervals.removeValue(forKey: key)
    }
  }
}
