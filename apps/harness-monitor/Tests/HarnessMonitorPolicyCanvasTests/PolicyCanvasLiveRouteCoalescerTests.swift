import Testing

@testable import HarnessMonitorPolicyCanvas

@MainActor
struct PolicyCanvasLiveRouteCoalescerTests {
  @Test("rapid schedules before the runner starts collapse into a single recompute")
  func rapidSchedulesCollapseIntoSingleRecompute() async {
    let coalescer = PolicyCanvasLiveRouteCoalescer()
    var runs = 0
    for _ in 0..<8 {
      coalescer.schedule { runs += 1 }
    }
    await coalescer.settle()
    #expect(runs == 1)
  }

  @Test("a schedule that arrives while work runs triggers exactly one more pass")
  func scheduleDuringWorkTriggersOneMorePass() async {
    let coalescer = PolicyCanvasLiveRouteCoalescer()
    var runs = 0
    coalescer.schedule {
      runs += 1
      if runs == 1 {
        // Re-entrant request: the runner must pick this up after the first pass.
        coalescer.schedule { runs += 1 }
      }
    }
    await coalescer.settle()
    #expect(runs == 2)
  }

  @Test("schedules in separate cycles each run once")
  func separateCyclesEachRunOnce() async {
    let coalescer = PolicyCanvasLiveRouteCoalescer()
    var runs = 0
    coalescer.schedule { runs += 1 }
    await coalescer.settle()
    coalescer.schedule { runs += 1 }
    await coalescer.settle()
    #expect(runs == 2)
  }
}
