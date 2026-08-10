import Testing

@testable import HarnessMonitorKit

@Suite("Legacy Monitor process detection")
struct LegacyMonitorProcessTests {
  @Test("Processes without a signed lane identity require containment")
  func missingLaneIdentityRequiresContainment() {
    #expect(DaemonController.legacyMonitorLabelNeedsContainment(nil))
  }

  @Test("Global service identities require containment")
  func globalServiceIdentityRequiresContainment() {
    #expect(
      DaemonController.legacyMonitorLabelNeedsContainment(
        "Q498EB36N4.io.harnessmonitor.agent"
      )
    )
  }

  @Test("Legacy service identities require containment")
  func legacyServiceIdentityRequiresContainment() {
    #expect(
      DaemonController.legacyMonitorLabelNeedsContainment(
        "io.harnessmonitor.daemon"
      )
    )
  }

  @Test("Lane-scoped signed identities can coexist")
  func laneScopedIdentityCanCoexist() {
    #expect(
      !DaemonController.legacyMonitorLabelNeedsContainment(
        "Q498EB36N4.io.harnessmonitor.agent-lane-a"
      )
    )
  }

  @Test("Process scan cache reuses clean results until lifecycle invalidation")
  func processScanCacheReusesResultsUntilInvalidation() async {
    let cache = LegacyMonitorProcessScanCache()
    let recorder = LegacyMonitorProcessScanRecorder()

    let first = await cache.value { await recorder.scan(result: false) }
    let second = await cache.value { await recorder.scan(result: true) }
    cache.invalidate()
    let third = await cache.value { await recorder.scan(result: true) }

    #expect(first == false)
    #expect(second == false)
    #expect(third)
    #expect(await recorder.callCount == 2)
  }
}

private actor LegacyMonitorProcessScanRecorder {
  private(set) var callCount = 0

  func scan(result: Bool) -> Bool {
    callCount += 1
    return result
  }
}
