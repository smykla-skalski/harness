import Foundation
import XCTest

@testable import HarnessMonitorKit

@MainActor
final class SupervisorStoreTickTriggerTests: XCTestCase {
  func test_burstScheduledSupervisorTicksCoalesceIntoSingleDrain() async {
    let store = HarnessMonitorStore.fixture()
    await store.startSupervisor()
    let baseline = store.supervisorScheduledTickCountsForTesting()

    for index in 0..<20 {
      store.scheduleSupervisorTick(reason: "burst-\(index)")
    }

    let deadline = Date().addingTimeInterval(2)
    while store.supervisorScheduledTickCountsForTesting().drains == baseline.drains
      && Date() < deadline
    {
      try? await Task.sleep(for: .milliseconds(5))
    }

    let counts = store.supervisorScheduledTickCountsForTesting()
    XCTAssertEqual(counts.requests - baseline.requests, 20)
    XCTAssertEqual(counts.drains - baseline.drains, 1)
    await store.stopSupervisor()
  }
}
