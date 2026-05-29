import Foundation
import Testing

@testable import HarnessMonitorKit

/// Guards the reviews-policy open enums against the Rust daemon's emitted
/// variants. Every Rust-emitted trigger/status raw value must round-trip
/// through `init(rawValue:)` without collapsing into `.unknown`.
struct ReviewsPolicyEnumDriftTests {
  @Test
  func triggerRoundTripsRustEmittedRawValues() {
    let rawValues = ["background", "manual", "manual_nudge", "event", "timer"]
    for raw in rawValues {
      let trigger = ReviewsPolicyTrigger(rawValue: raw)
      if case .unknown = trigger {
        Issue.record("trigger \(raw) decoded to .unknown")
      }
      #expect(trigger.rawValue == raw)
    }
  }

  @Test
  func triggerAllCasesCoversRustEmittedValues() {
    let rawValues = Set(ReviewsPolicyTrigger.allCases.map(\.rawValue))
    #expect(rawValues.isSuperset(of: ["manual", "background", "event", "timer", "manual_nudge"]))
  }

  @Test
  func runStatusRoundTripsRustEmittedRawValues() {
    let rawValues = ["running", "waiting", "completed", "failed", "cancelled"]
    for raw in rawValues {
      let status = ReviewsPolicyRunStatus(rawValue: raw)
      if case .unknown = status {
        Issue.record("status \(raw) decoded to .unknown")
      }
      #expect(status.rawValue == raw)
    }
  }
}
