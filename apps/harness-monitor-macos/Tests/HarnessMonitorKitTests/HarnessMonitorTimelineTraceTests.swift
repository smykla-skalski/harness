import Foundation
import Testing

@testable import HarnessMonitorKit

@Suite("Harness Monitor timeline trace")
struct HarnessMonitorTimelineTraceTests {
  @Test("Disabled timeline trace does not evaluate message")
  func disabledTimelineTraceDoesNotEvaluateMessage() {
    var didEvaluate = false

    HarnessMonitorTimelineTrace.log({
      didEvaluate = true
      return "expensive trace payload"
    }, enabled: false)

    #expect(didEvaluate == false)
  }

  @Test("Timeline trace flag reads defaults")
  func timelineTraceFlagReadsDefaults() throws {
    let defaults = try isolatedTimelineTraceDefaults()

    #expect(
      HarnessMonitorTimelineTrace.isEnabled(
        environmentEnabled: false,
        defaults: defaults
      ) == false
    )

    defaults.set(true, forKey: HarnessMonitorTimelineTrace.defaultsKey)

    #expect(
      HarnessMonitorTimelineTrace.isEnabled(
        environmentEnabled: false,
        defaults: defaults
      ) == true
    )
    #expect(
      HarnessMonitorTimelineTrace.isEnabled(
        environmentEnabled: true,
        defaults: defaults
      ) == true
    )
  }
}

private func isolatedTimelineTraceDefaults() throws -> UserDefaults {
  let suiteName = "HarnessMonitorTimelineTraceTests.\(UUID().uuidString)"
  let defaults = try #require(UserDefaults(suiteName: suiteName))
  defaults.removePersistentDomain(forName: suiteName)
  return defaults
}
