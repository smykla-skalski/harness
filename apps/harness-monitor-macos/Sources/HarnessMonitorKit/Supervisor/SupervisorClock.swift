import Foundation

public protocol SupervisorClock: Sendable {
  func now() -> Date
  func sleep(for duration: Duration) async throws
}

public struct WallClock: SupervisorClock {
  public init() {}

  public func now() -> Date { Date() }

  public func sleep(for duration: Duration) async throws {
    try await Task.sleep(for: duration)
  }
}
