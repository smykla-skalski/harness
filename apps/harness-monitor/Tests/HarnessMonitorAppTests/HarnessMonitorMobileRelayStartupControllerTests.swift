import Foundation
import XCTest

@testable import HarnessMonitor
import HarnessMonitorKit

@MainActor
final class HarnessMonitorMobileRelayStartupControllerTests: XCTestCase {
  func testRuntimeBuilderRunsOnceOffMainThread() async {
    let store = HarnessMonitorStore(daemonController: PreviewDaemonController(mode: .empty))
    let probe = MobileRelayStartupThreadProbe()
    let controller = HarnessMonitorMobileRelayStartupController(
      environment: HarnessMonitorEnvironment(values: [:]),
      store: store,
      runsLiveSideEffects: true,
      runtimeBuilder: {
        probe.recordCurrentThread()
        return nil
      }
    )

    controller.start()
    controller.start()
    await controller.waitForStartup()

    let snapshot = probe.snapshot()
    XCTAssertEqual(snapshot.invocationCount, 1)
    XCTAssertFalse(snapshot.ranOnMainThread)
    XCTAssertNil(controller.runtime)
  }
}

private final class MobileRelayStartupThreadProbe: @unchecked Sendable {
  private let lock = NSLock()
  private var invocationCount = 0
  private var ranOnMainThread = false

  func recordCurrentThread() {
    lock.withLock {
      invocationCount += 1
      ranOnMainThread = Thread.isMainThread
    }
  }

  func snapshot() -> (invocationCount: Int, ranOnMainThread: Bool) {
    lock.withLock { (invocationCount, ranOnMainThread) }
  }
}
