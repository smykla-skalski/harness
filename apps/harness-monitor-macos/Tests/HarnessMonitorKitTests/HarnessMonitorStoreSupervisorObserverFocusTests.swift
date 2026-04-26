import Foundation
import Testing

@testable import HarnessMonitorKit

@MainActor
@Suite("Supervisor observer focus")
struct HarnessMonitorStoreSupervisorObserverFocusTests {
  @Test("supervisorObserverFocusTick starts at zero")
  func tickStartsAtZero() {
    let store = HarnessMonitorStore(daemonController: RecordingDaemonController())
    #expect(store.supervisorObserverFocusTick == 0)
  }

  @Test("requestObserverFocusInDecisions increments the tick once per call")
  func requestObserverFocusBumpsTick() {
    let store = HarnessMonitorStore(daemonController: RecordingDaemonController())

    store.requestObserverFocusInDecisions()
    #expect(store.supervisorObserverFocusTick == 1)

    store.requestObserverFocusInDecisions()
    store.requestObserverFocusInDecisions()
    #expect(store.supervisorObserverFocusTick == 3)
  }
}
