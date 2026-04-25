import Foundation

public struct WarmUpBackoff: Sendable {
  public let initial: Duration
  public let multiplier: Double
  public let cap: Duration
  let sleeper: @Sendable (Duration) async throws -> Void

  public init(
    initial: Duration,
    multiplier: Double,
    cap: Duration,
    sleeper: @escaping @Sendable (Duration) async throws -> Void = { duration in
      try await Task.sleep(for: duration)
    }
  ) {
    self.initial = initial
    self.multiplier = multiplier
    self.cap = cap
    self.sleeper = sleeper
  }

  public static let `default` = Self(
    initial: .milliseconds(250),
    multiplier: 1.5,
    cap: .milliseconds(1500)
  )

  func makeIterator() -> Iterator {
    Iterator(initial: initial, multiplier: multiplier, cap: cap, sleeper: sleeper)
  }

  struct Iterator {
    let initial: Duration
    let multiplier: Double
    let cap: Duration
    let sleeper: @Sendable (Duration) async throws -> Void
    private(set) var currentInterval: Duration

    init(
      initial: Duration,
      multiplier: Double,
      cap: Duration,
      sleeper: @escaping @Sendable (Duration) async throws -> Void
    ) {
      self.initial = initial
      self.multiplier = multiplier
      self.cap = cap
      self.sleeper = sleeper
      currentInterval = initial
    }

    mutating func wait() async throws {
      try await sleeper(currentInterval)
      currentInterval = min(currentInterval * multiplier, cap)
    }

    mutating func reset() {
      currentInterval = initial
    }
  }
}
