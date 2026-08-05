import Foundation
import Testing

@testable import HarnessMonitorKit

@Suite("External session store")
@MainActor
struct ExternalSessionStoreTests {
  @Test("requestAttachExternalSession remains pending until a host consumes it")
  func requestRemainsPendingUntilConsumed() {
    let store = HarnessMonitorStore(daemonController: RecordingDaemonController())
    let before = store.attachSessionRequest

    store.requestAttachExternalSession()

    #expect(store.attachSessionRequest == before + 1)
    #expect(store.hasPendingAttachSessionRequest)
    #expect(store.consumeAttachSessionRequest())
    #expect(!store.hasPendingAttachSessionRequest)
    #expect(!store.consumeAttachSessionRequest())
  }
}
