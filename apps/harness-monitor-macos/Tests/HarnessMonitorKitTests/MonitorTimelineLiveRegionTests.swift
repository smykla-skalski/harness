import Foundation
import Testing

@testable import HarnessMonitorUIPreviewable

@MainActor
@Suite("Monitor timeline live-region priority")
struct MonitorTimelineLiveRegionPriorityTests {
  @Test("Polite kinds map to polite priority")
  func politeKinds() {
    #expect(MonitorTimelineLiveRegion.priority(for: "tool_result") == .polite)
    #expect(MonitorTimelineLiveRegion.priority(for: "tool_result_error") == .polite)
  }

  @Test("Assertive kinds map to assertive priority")
  func assertiveKinds() {
    #expect(MonitorTimelineLiveRegion.priority(for: "agent_watchdog_state") == .assertive)
    #expect(MonitorTimelineLiveRegion.priority(for: "agent_session_marker") == .assertive)
    #expect(MonitorTimelineLiveRegion.priority(for: "agent_error") == .assertive)
  }

  @Test("Kinds without a Rust producer default to silent")
  func unproducedKindsAreSilent() {
    #expect(MonitorTimelineLiveRegion.priority(for: "agent_permission_asked") == .silent)
    #expect(MonitorTimelineLiveRegion.priority(for: "agent_hook_fired") == .silent)
    #expect(MonitorTimelineLiveRegion.priority(for: "agent_context_injected") == .silent)
    #expect(MonitorTimelineLiveRegion.priority(for: "plan_update") == .silent)
  }

  @Test("Unknown kinds default to silent so they never reach VoiceOver")
  func unknownKindsAreSilent() {
    #expect(MonitorTimelineLiveRegion.priority(for: "user_prompt") == .silent)
    #expect(MonitorTimelineLiveRegion.priority(for: "assistant_text_chunk") == .silent)
    #expect(MonitorTimelineLiveRegion.priority(for: "thought") == .silent)
    #expect(MonitorTimelineLiveRegion.priority(for: "") == .silent)
    #expect(MonitorTimelineLiveRegion.priority(for: "totally_made_up_kind") == .silent)
  }
}

@MainActor
@Suite("Monitor timeline live-region throttle")
struct MonitorTimelineLiveRegionThrottleTests {
  @Test("Polite within minimum gap is dropped")
  func politeBurstCollapsesToOne() {
    let throttle = MonitorTimelineLiveRegionThrottle()
    let start = ContinuousClock.now
    var fired = 0

    func fire(at offset: Duration) {
      let before = throttle.lastPoliteInstant
      throttle.announceIfAllowed("entry", priority: .polite, now: start.advanced(by: offset))
      if throttle.lastPoliteInstant != before {
        fired += 1
      }
    }

    fire(at: .zero)
    fire(at: .milliseconds(100))
    fire(at: .milliseconds(500))
    fire(at: .milliseconds(900))

    #expect(fired == 1)
  }

  @Test("Polite past the minimum gap fires again")
  func politePastGapFiresAgain() {
    let throttle = MonitorTimelineLiveRegionThrottle()
    let start = ContinuousClock.now
    var fired = 0

    func fire(at offset: Duration) {
      let before = throttle.lastPoliteInstant
      throttle.announceIfAllowed("entry", priority: .polite, now: start.advanced(by: offset))
      if throttle.lastPoliteInstant != before {
        fired += 1
      }
    }

    fire(at: .zero)
    fire(at: .milliseconds(1100))
    fire(at: .milliseconds(2300))

    #expect(fired == 3)
  }

  @Test("Assertive bypasses the throttle and never bumps polite cooldown")
  func assertiveBypassesThrottle() {
    let throttle = MonitorTimelineLiveRegionThrottle()
    let start = ContinuousClock.now
    let urgentAt50 = start.advanced(by: .milliseconds(50))
    let urgentAt100 = start.advanced(by: .milliseconds(100))

    throttle.announceIfAllowed("polite", priority: .polite, now: start)
    let politeInstant = throttle.lastPoliteInstant

    throttle.announceIfAllowed("urgent", priority: .assertive, now: urgentAt50)
    throttle.announceIfAllowed("urgent2", priority: .assertive, now: urgentAt100)

    #expect(throttle.lastPoliteInstant == politeInstant)
  }

  @Test("Silent priority is a no-op")
  func silentNoOp() {
    let throttle = MonitorTimelineLiveRegionThrottle()
    throttle.announceIfAllowed("ignored", priority: .silent)
    #expect(throttle.lastPoliteInstant == nil)
  }

  @Test("Polite drops do not bump cooldown")
  func droppedPoliteDoesNotBumpCooldown() {
    let throttle = MonitorTimelineLiveRegionThrottle()
    let start = ContinuousClock.now
    let secondAnnouncementAt = start.advanced(by: .milliseconds(200))
    let thirdAnnouncementAt = start.advanced(by: .milliseconds(800))

    throttle.announceIfAllowed("first", priority: .polite, now: start)
    let firstInstant = throttle.lastPoliteInstant

    throttle.announceIfAllowed("second", priority: .polite, now: secondAnnouncementAt)
    throttle.announceIfAllowed("third", priority: .polite, now: thirdAnnouncementAt)

    #expect(throttle.lastPoliteInstant == firstInstant)
  }
}
