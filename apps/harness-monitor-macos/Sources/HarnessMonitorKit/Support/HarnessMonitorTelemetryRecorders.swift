import Foundation
import OpenTelemetryApi

final class HarnessMonitorLongCounterRecorder: @unchecked Sendable {
  private let lock = NSLock()
  private var counter: any LongCounter

  init(counter: some LongCounter) {
    self.counter = counter
  }

  func add(value: Int, attributes: [String: AttributeValue]) {
    lock.withLock {
      counter.add(value: value, attributes: attributes)
    }
  }
}

final class HarnessMonitorLongGaugeRecorder: @unchecked Sendable {
  private let lock = NSLock()
  private var gauge: any LongGauge

  init(gauge: some LongGauge) {
    self.gauge = gauge
  }

  func record(value: Int, attributes: [String: AttributeValue]) {
    lock.withLock {
      gauge.record(value: value, attributes: attributes)
    }
  }
}

final class HarnessMonitorDoubleHistogramRecorder: @unchecked Sendable {
  private let lock = NSLock()
  private var histogram: any DoubleHistogram

  init(histogram: some DoubleHistogram) {
    self.histogram = histogram
  }

  func record(value: Double, attributes: [String: AttributeValue]) {
    lock.withLock {
      histogram.record(value: value, attributes: attributes)
    }
  }
}
