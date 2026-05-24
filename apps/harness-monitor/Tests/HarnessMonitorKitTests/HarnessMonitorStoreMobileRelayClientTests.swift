import XCTest

@testable import HarnessMonitorKit

@MainActor
final class HarnessMonitorStoreMobileRelayClientTests: XCTestCase {
  func testMobileRelayClientUsesActiveStoreClientWithoutWarmUp() async throws {
    let daemon = RecordingDaemonController()
    let store = HarnessMonitorStore(daemonController: daemon)
    store.client = PreviewHarnessClient()

    _ = try await store.clientForMobileRelay()
    let warmUpCallCount = await daemon.recordedWarmUpCallCount()

    XCTAssertEqual(warmUpCallCount, 0)
  }

  func testMobileRelayClientWarmsDaemonWhenAppConnectionIsSuspended() async throws {
    let daemon = RecordingDaemonController(client: PreviewHarnessClient())
    let store = HarnessMonitorStore(daemonController: daemon)
    store.isAppLifecycleSuspended = true

    let client = try await store.clientForMobileRelay()
    let warmUpCallCount = await daemon.recordedWarmUpCallCount()

    XCTAssertNotNil(client)
    XCTAssertNil(store.apiClient)
    XCTAssertEqual(warmUpCallCount, 1)
  }
}
