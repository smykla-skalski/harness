import Foundation
import Testing

@testable import HarnessMonitorKit

@Suite("External session store")
@MainActor
struct ExternalSessionStoreTests {
  @Test("requestAttachExternalSession bumps counter")
  func bumpsCounter() {
    let store = HarnessMonitorStore(daemonController: RecordingDaemonController())
    let before = store.attachSessionRequest
    store.requestAttachExternalSession()
    #expect(store.attachSessionRequest == before + 1)
  }
}
