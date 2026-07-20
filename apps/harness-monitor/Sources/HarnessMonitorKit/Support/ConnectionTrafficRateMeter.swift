import Foundation

/// Rolling messages-per-second meter over a fixed window.
///
/// Traffic used to be tracked as one `Date` per message and re-scanned in full
/// on every event to drop stale samples: quadratic during a burst, and
/// unbounded in memory for as long as messages kept landing inside the window.
/// Counting into per-second buckets makes both costs constant - a burst only
/// increments one bucket, and the meter never holds more than `windowSeconds`
/// of them.
struct ConnectionTrafficRateMeter {
  static let defaultWindowSeconds = 30

  private var buckets: [Int]
  private var total = 0
  private var newestSecond: Int?

  init(windowSeconds: Int = ConnectionTrafficRateMeter.defaultWindowSeconds) {
    buckets = Array(repeating: 0, count: max(1, windowSeconds))
  }

  /// Messages per second averaged across the whole window.
  var messagesPerSecond: Double {
    Double(total) / Double(buckets.count)
  }

  /// Counts `count` messages at `timestamp` and returns the resulting rate.
  mutating func record(count: Int, at timestamp: Date) -> Double {
    let second = Self.second(for: timestamp)
    guard let newestSecond else {
      self.newestSecond = second
      add(count, at: second)
      return messagesPerSecond
    }
    if second > newestSecond {
      slideWindow(from: newestSecond, to: second)
      self.newestSecond = second
    } else if second <= newestSecond - buckets.count {
      // Older than the window. Its bucket now belongs to a newer second, so
      // counting it there would inflate the rate instead of expiring quietly.
      return messagesPerSecond
    }
    add(count, at: second)
    return messagesPerSecond
  }

  mutating func reset() {
    for index in buckets.indices {
      buckets[index] = 0
    }
    total = 0
    newestSecond = nil
  }

  private mutating func add(_ count: Int, at second: Int) {
    buckets[index(for: second)] += count
    total += count
  }

  /// Clears the buckets the window just moved past so their counts stop
  /// contributing to the rate.
  private mutating func slideWindow(from previous: Int, to second: Int) {
    let steps = min(second - previous, buckets.count)
    for step in 1...steps {
      let index = index(for: previous + step)
      total -= buckets[index]
      buckets[index] = 0
    }
  }

  private func index(for second: Int) -> Int {
    let raw = second % buckets.count
    return raw < 0 ? raw + buckets.count : raw
  }

  private static func second(for timestamp: Date) -> Int {
    Int(timestamp.timeIntervalSinceReferenceDate.rounded(.down))
  }
}
