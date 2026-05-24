import Foundation
import HarnessMonitorKit
import XCTest

@testable import HarnessMonitorIntents

final class IntentDaemonClientCacheTests: XCTestCase {
  func testReturnsSameClientWithinTTL() async throws {
    let clock = TestClock(start: Date(timeIntervalSince1970: 1_000))
    let builder = ClientBuilder()
    let cache = IntentDaemonClientCache(
      ttl: 60,
      now: { clock.current },
      clientBuilder: builder.build
    )

    let first = try await cache.client()
    clock.advance(by: 30)
    let second = try await cache.client()

    XCTAssertTrue(first === second)
    XCTAssertEqual(builder.callCount, 1)
  }

  func testRebuildsAfterTTL() async throws {
    let clock = TestClock(start: Date(timeIntervalSince1970: 1_000))
    let builder = ClientBuilder()
    let cache = IntentDaemonClientCache(
      ttl: 60,
      now: { clock.current },
      clientBuilder: builder.build
    )

    let first = try await cache.client()
    clock.advance(by: 61)
    let second = try await cache.client()

    XCTAssertFalse(first === second)
    XCTAssertEqual(builder.callCount, 2)
  }

  func testInvalidateDropsCachedClient() async throws {
    let builder = ClientBuilder()
    let cache = IntentDaemonClientCache(clientBuilder: builder.build)

    _ = try await cache.client()
    let cachedBefore = await cache.hasCachedClientForTesting
    XCTAssertTrue(cachedBefore)

    await cache.invalidate()

    let cachedAfter = await cache.hasCachedClientForTesting
    XCTAssertFalse(cachedAfter)

    _ = try await cache.client()
    XCTAssertEqual(builder.callCount, 2)
  }

  func testBuilderThrowDoesNotPopulateCache() async throws {
    let cache = IntentDaemonClientCache(
      clientBuilder: { _ in
        throw IntentDaemonError.daemonUnavailable(reason: "test")
      }
    )

    do {
      _ = try await cache.client()
      XCTFail("expected throw")
    } catch let error as IntentDaemonError {
      guard case .daemonUnavailable = error else {
        XCTFail("unexpected error: \(error)")
        return
      }
    }

    let cached = await cache.hasCachedClientForTesting
    XCTAssertFalse(cached)
  }
}

private final class TestClock: @unchecked Sendable {
  private let lock = NSLock()
  private var time: Date

  init(start: Date) {
    self.time = start
  }

  var current: Date {
    lock.lock()
    defer { lock.unlock() }
    return time
  }

  func advance(by seconds: TimeInterval) {
    lock.lock()
    defer { lock.unlock() }
    time = time.addingTimeInterval(seconds)
  }
}

private final class ClientBuilder: @unchecked Sendable {
  private let lock = NSLock()
  private var count = 0

  var callCount: Int {
    lock.lock()
    defer { lock.unlock() }
    return count
  }

  func build(_ environment: HarnessMonitorEnvironment) throws -> IntentDaemonClient {
    lock.lock()
    defer { lock.unlock() }
    count += 1
    let connection = HarnessMonitorConnection(
      endpoint: URL(string: "ws://127.0.0.1:1/")!,
      token: "test-token"
    )
    return IntentDaemonClient(connection: connection)
  }
}
