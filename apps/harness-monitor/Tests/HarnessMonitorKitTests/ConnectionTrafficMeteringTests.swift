import Foundation
import Testing

@testable import HarnessMonitorKit

@MainActor
@Suite("Connection traffic metering")
struct ConnectionTrafficMeteringTests {
  @Test("Stream traffic leaves persistent connection chrome unchanged")
  func streamTrafficLeavesPersistentConnectionChromeUnchanged() async {
    let store = await makeBootstrappedStore()
    let eventCount = 50
    let originalStatusMetrics = store.connectionStatusMetrics
    let originalMessageCount = store.connectionMetrics.messagesReceived
    var sidebarSyncCountAfterTraffic = -1

    store.debugResetUISyncCounts()
    let invalidations = await invalidationCount(
      { store.connectionStatusMetrics },
      after: {
        for index in 0..<eventCount {
          store.recordStreamEvent(
            countedInTraffic: true,
            recordedAt: Date(
              timeIntervalSinceReferenceDate: 1_000_000 + Double(index) / 100
            )
          )
        }
        sidebarSyncCountAfterTraffic = store.debugUISyncCount(for: .sidebar)
      }
    )

    #expect(store.connectionMetrics.messagesReceived == originalMessageCount + eventCount)
    #expect(store.connectionStatusMetrics == originalStatusMetrics)
    #expect(invalidations == 0)
    #expect(sidebarSyncCountAfterTraffic == 0)
  }

  @Test("Request latency updates connection chrome without a sidebar slice sync")
  func requestLatencyUpdatesConnectionChromeWithoutSidebarSliceSync() async {
    let store = await makeBootstrappedStore()
    let recordedAt = Date(timeIntervalSinceReferenceDate: 2_000_000)
    let connectedSince = store.connectionStatusMetrics.connectedSince

    store.debugResetUISyncCounts()
    let invalidations = await invalidationCount(
      { store.connectionStatusMetrics },
      after: {
        store.recordRequestSuccess(
          latencyMs: 73,
          latencySource: .request,
          recordedAt: recordedAt
        )
      }
    )

    #expect(store.connectionStatusMetrics.requestLatencyMs == 73)
    #expect(store.connectionStatusMetrics.connectedSince == connectedSince)
    #expect(invalidations == 1)
    #expect(store.debugUISyncCount(for: .sidebar) == 0)
  }
}

@Suite("Connection traffic rate meter")
struct ConnectionTrafficRateMeterTests {
  private let anchor = Date(timeIntervalSinceReferenceDate: 1_000_000)

  @Test("A steady stream reports its arrival rate")
  func steadyStreamReportsArrivalRate() {
    var meter = ConnectionTrafficRateMeter(windowSeconds: 30)

    for second in 0..<30 {
      _ = meter.record(count: 3, at: anchor.addingTimeInterval(Double(second)))
    }

    #expect(meter.messagesPerSecond == 3)
  }

  @Test("Messages count for the window and no longer")
  func messagesCountForTheWindowAndNoLonger() {
    var meter = ConnectionTrafficRateMeter(windowSeconds: 30)

    _ = meter.record(count: 30, at: anchor)
    #expect(meter.messagesPerSecond == 1)

    // One second short of the window: the burst still counts.
    _ = meter.record(count: 0, at: anchor.addingTimeInterval(29))
    #expect(meter.messagesPerSecond == 1)

    _ = meter.record(count: 0, at: anchor.addingTimeInterval(30))
    #expect(meter.messagesPerSecond == 0)
  }

  @Test("Skipping past the whole window clears every bucket")
  func skippingPastTheWholeWindowClearsEveryBucket() {
    var meter = ConnectionTrafficRateMeter(windowSeconds: 30)

    for second in 0..<30 {
      _ = meter.record(count: 10, at: anchor.addingTimeInterval(Double(second)))
    }
    #expect(meter.messagesPerSecond == 10)

    let rate = meter.record(count: 0, at: anchor.addingTimeInterval(5_000))
    #expect(rate == 0)
  }

  @Test("Samples older than the window are ignored")
  func samplesOlderThanTheWindowAreIgnored() {
    var meter = ConnectionTrafficRateMeter(windowSeconds: 30)

    _ = meter.record(count: 30, at: anchor.addingTimeInterval(100))
    let rate = meter.record(count: 600, at: anchor)

    #expect(rate == 1)
    #expect(meter.messagesPerSecond == 1)
  }

  @Test("A burst inside one second stays bounded and rated")
  func burstInsideOneSecondStaysBoundedAndRated() {
    var meter = ConnectionTrafficRateMeter(windowSeconds: 30)

    for index in 0..<100_000 {
      _ = meter.record(count: 1, at: anchor.addingTimeInterval(Double(index) / 100_000))
    }

    #expect(meter.messagesPerSecond == Double(100_000) / 30)
  }

  @Test("Reset drops the whole window")
  func resetDropsTheWholeWindow() {
    var meter = ConnectionTrafficRateMeter(windowSeconds: 30)
    _ = meter.record(count: 300, at: anchor)

    meter.reset()

    #expect(meter.messagesPerSecond == 0)
    // The next sample starts a fresh window rather than reviving the old one.
    #expect(meter.record(count: 30, at: anchor.addingTimeInterval(1)) == 1)
  }
}
