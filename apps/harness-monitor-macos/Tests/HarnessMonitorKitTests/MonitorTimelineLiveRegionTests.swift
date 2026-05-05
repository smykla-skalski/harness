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
    #expect(MonitorTimelineLiveRegion.priority(for: "agent_context_injected") == .polite)
  }

  @Test("Assertive kinds map to assertive priority")
  func assertiveKinds() {
    #expect(MonitorTimelineLiveRegion.priority(for: "agent_session_marker") == .assertive)
    #expect(MonitorTimelineLiveRegion.priority(for: "agent_error") == .assertive)
    #expect(MonitorTimelineLiveRegion.priority(for: "agent_permission_asked") == .assertive)
  }

  @Test("Watchdog idle and active transitions are polite")
  func watchdogIdleStaysPolite() {
    #expect(
      MonitorTimelineLiveRegion.priority(
        for: "agent_watchdog_state",
        summary: "Watchdog Active"
      ) == .polite
    )
    #expect(
      MonitorTimelineLiveRegion.priority(
        for: "agent_watchdog_state",
        summary: "Watchdog Armed"
      ) == .polite
    )
    #expect(
      MonitorTimelineLiveRegion.priority(
        for: "agent_watchdog_state",
        summary: ""
      ) == .polite
    )
  }

  @Test("Watchdog fired transitions stay assertive")
  func watchdogFiredIsAssertive() {
    #expect(
      MonitorTimelineLiveRegion.priority(
        for: "agent_watchdog_state",
        summary: "Watchdog Fired"
      ) == .assertive
    )
    #expect(
      MonitorTimelineLiveRegion.priority(
        for: "agent_watchdog_state",
        summary: "watchdog expired after 60s"
      ) == .assertive
    )
    #expect(
      MonitorTimelineLiveRegion.priority(
        for: "agent_watchdog_state",
        summary: "agent timed out"
      ) == .assertive
    )
  }

  @Test("Signal sent and received are polite")
  func signalSentAndReceivedArePolite() {
    #expect(MonitorTimelineLiveRegion.priority(for: "signal_sent") == .polite)
    #expect(MonitorTimelineLiveRegion.priority(for: "signal_received") == .polite)
  }

  @Test("Signal acknowledged is polite on acceptance and assertive on rejection variants")
  func signalAcknowledgedPriorityDispatchesOnSummary() {
    #expect(
      MonitorTimelineLiveRegion.priority(
        for: "signal_acknowledged",
        summary: "sig-abc delivered to codex-worker: Accepted"
      ) == .polite
    )
    #expect(
      MonitorTimelineLiveRegion.priority(
        for: "signal_acknowledged",
        summary: "sig-abc rejected from codex-worker: Rejected"
      ) == .assertive
    )
    #expect(
      MonitorTimelineLiveRegion.priority(
        for: "signal_acknowledged",
        summary: "sig-abc deferred by codex-worker: Deferred"
      ) == .assertive
    )
    #expect(
      MonitorTimelineLiveRegion.priority(
        for: "signal_acknowledged",
        summary: "sig-abc expired without acknowledgement: Expired"
      ) == .assertive
    )
  }

  @Test("Kinds without a Rust producer default to silent")
  func unproducedKindsAreSilent() {
    #expect(MonitorTimelineLiveRegion.priority(for: "agent_hook_fired") == .silent)
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
    fire(at: .seconds(1))
    fire(at: .seconds(5))
    fire(at: .seconds(9))

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
    fire(at: .seconds(11))
    fire(at: .seconds(23))

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
    let secondAt = start.advanced(by: .seconds(2))
    let thirdAt = start.advanced(by: .seconds(8))

    throttle.announceIfAllowed("first", priority: .polite, now: start)
    let firstInstant = throttle.lastPoliteInstant

    throttle.announceIfAllowed("second", priority: .polite, now: secondAt)
    throttle.announceIfAllowed("third", priority: .polite, now: thirdAt)

    #expect(throttle.lastPoliteInstant == firstInstant)
  }

  @Test("Polite drops accumulate then roll up into next announcement")
  func dropsRollUpIntoNextAnnouncement() {
    let throttle = MonitorTimelineLiveRegionThrottle()
    let start = ContinuousClock.now

    throttle.announceIfAllowed("first", priority: .polite, now: start)
    throttle.announceIfAllowed("dropped 1", priority: .polite, now: start.advanced(by: .seconds(1)))
    throttle.announceIfAllowed("dropped 2", priority: .polite, now: start.advanced(by: .seconds(3)))
    throttle.announceIfAllowed("dropped 3", priority: .polite, now: start.advanced(by: .seconds(5)))

    #expect(throttle.droppedPoliteSinceLast == 3)

    throttle.announceIfAllowed(
      "next",
      priority: .polite,
      now: start.advanced(by: .seconds(15))
    )

    #expect(throttle.droppedPoliteSinceLast == 0)
  }

  @Test("Compose rollup with no drops returns summary unchanged")
  func composeNoDropsPassesThrough() {
    #expect(
      MonitorTimelineLiveRegionThrottle.composeRolledUpSummary("hello", droppedSinceLast: 0)
        == "hello"
    )
  }

  @Test("Compose rollup with one drop pluralizes correctly")
  func composeOneDropSingular() {
    #expect(
      MonitorTimelineLiveRegionThrottle.composeRolledUpSummary("hello", droppedSinceLast: 1)
        == "Plus 1 more update. hello"
    )
  }

  @Test("Compose rollup with multiple drops uses plural")
  func composeMultipleDropsPlural() {
    #expect(
      MonitorTimelineLiveRegionThrottle.composeRolledUpSummary("hello", droppedSinceLast: 5)
        == "Plus 5 more updates. hello"
    )
  }
}
