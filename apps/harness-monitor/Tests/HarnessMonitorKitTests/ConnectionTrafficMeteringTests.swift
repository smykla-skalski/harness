import Foundation
import Testing

@testable import HarnessMonitorKit

@MainActor
@Suite("Connection traffic metering")
struct ConnectionTrafficMeteringTests {
  @Test("A streamed event costs one sidebar sync")
  func streamedEventCostsOneSidebarSync() async {
    let store = await makeBootstrappedStore()
    let eventCount = 50

    store.debugResetUISyncCounts()
    for index in 0..<eventCount {
      store.recordStreamEvent(
        countedInTraffic: true,
        recordedAt: Date(timeIntervalSinceReferenceDate: 1_000_000 + Double(index) / 100)
      )
    }

    #expect(store.debugUISyncCount(for: .sidebar) == eventCount)
  }

  @Test("A successful request costs one sidebar sync")
  func successfulRequestCostsOneSidebarSync() async {
    let store = await makeBootstrappedStore()
    let requestCount = 25

    store.debugResetUISyncCounts()
    for index in 0..<requestCount {
      store.recordRequestSuccess(
        latencyMs: 20 + index,
        latencySource: .request,
        recordedAt: Date(timeIntervalSinceReferenceDate: 2_000_000 + Double(index) / 100)
      )
    }

    #expect(store.debugUISyncCount(for: .sidebar) == requestCount)
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
