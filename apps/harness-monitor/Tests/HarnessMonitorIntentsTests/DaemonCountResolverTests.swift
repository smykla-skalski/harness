import Foundation
import HarnessMonitorKit
import XCTest

@testable import HarnessMonitorIntents

final class DaemonCountResolverTests: XCTestCase {
  func testFirstSuccessfulResolveCachesClient() async throws {
    let factory = ClientFactory(values: [42])
    let resolver = DaemonCountResolver(
      environment: HarnessMonitorEnvironment(),
      buildClient: { _ in try factory.makeClient() }
    )

    let count = try await resolver.resolve()
    let cachedAfter = await resolver.hasCachedClient

    XCTAssertEqual(count, 42)
    XCTAssertTrue(cachedAfter, "Resolver must cache the client after a successful call")
    XCTAssertEqual(factory.buildCount, 1)
  }

  func testRepeatedSuccessReusesSingleClient() async throws {
    let factory = ClientFactory(values: [7, 7, 7])
    let resolver = DaemonCountResolver(
      environment: HarnessMonitorEnvironment(),
      buildClient: { _ in try factory.makeClient() }
    )

    _ = try await resolver.resolve()
    _ = try await resolver.resolve()
    _ = try await resolver.resolve()

    let calls = await factory.callCountFromLastClient()
    XCTAssertEqual(factory.buildCount, 1, "Resolver must reuse cached client across successful calls")
    XCTAssertEqual(calls, 3)
  }

  func testFailureInvalidatesCachedClient() async {
    let client = FakeDaemonCountClient(behavior: .throws)
    let resolver = DaemonCountResolver(
      environment: HarnessMonitorEnvironment(),
      buildClient: { _ in client }
    )

    _ = try? await resolver.resolve()

    let cached = await resolver.hasCachedClient
    XCTAssertFalse(cached, "Failure must drop the cached client")
  }

  func testResolveAfterFailureBuildsFreshClient() async throws {
    let throwingClient = FakeDaemonCountClient(behavior: .throws)
    let workingClient = FakeDaemonCountClient(behavior: .returns([99]))
    let factory = ScriptedClientFactory(scripted: [throwingClient, workingClient])
    let resolver = DaemonCountResolver(
      environment: HarnessMonitorEnvironment(),
      buildClient: { _ in try factory.next() }
    )

    _ = try? await resolver.resolve()
    let count = try await resolver.resolve()

    XCTAssertEqual(count, 99)
    XCTAssertEqual(factory.cursor, 2, "Second call after failure must rebuild client")
  }

  func testBuildClientThrowDoesNotPopulateCache() async {
    let resolver = DaemonCountResolver(
      environment: HarnessMonitorEnvironment(),
      buildClient: { _ in throw FakeError.buildFailed }
    )

    _ = try? await resolver.resolve()

    let cached = await resolver.hasCachedClient
    XCTAssertFalse(cached)
  }

  func testInvalidateDropsCachedClient() async throws {
    let factory = ClientFactory(values: [3])
    let resolver = DaemonCountResolver(
      environment: HarnessMonitorEnvironment(),
      buildClient: { _ in try factory.makeClient() }
    )

    _ = try await resolver.resolve()
    let cachedBeforeInvalidate = await resolver.hasCachedClient
    XCTAssertTrue(cachedBeforeInvalidate)

    await resolver.invalidate()

    let cachedAfterInvalidate = await resolver.hasCachedClient
    XCTAssertFalse(cachedAfterInvalidate)
  }
}

private final class ClientFactory: @unchecked Sendable {
  private(set) var buildCount = 0
  private var values: [Int]
  private var lastClient: FakeDaemonCountClient?

  init(values: [Int]) {
    self.values = values
  }

  func makeClient() throws -> DaemonCountClient {
    buildCount += 1
    let client = FakeDaemonCountClient(behavior: .returns(values))
    lastClient = client
    return client
  }

  func callCountFromLastClient() async -> Int {
    guard let lastClient else { return 0 }
    return await lastClient.callCount
  }
}

private final class ScriptedClientFactory: @unchecked Sendable {
  private(set) var cursor = 0
  private var scripted: [DaemonCountClient]

  init(scripted: [DaemonCountClient]) {
    self.scripted = scripted
  }

  func next() throws -> DaemonCountClient {
    guard cursor < scripted.count else {
      throw FakeError.noMoreClients
    }
    let client = scripted[cursor]
    cursor += 1
    return client
  }
}

private actor FakeDaemonCountClient: DaemonCountClient {
  enum Behavior {
    case returns([Int])
    case `throws`
  }

  private var behavior: Behavior
  private(set) var callCount = 0

  init(behavior: Behavior) {
    self.behavior = behavior
  }

  func countNeedsMeReviewItems() async throws -> Int {
    callCount += 1
    switch behavior {
    case .returns(var values):
      guard !values.isEmpty else { throw FakeError.exhausted }
      let next = values.removeFirst()
      behavior = .returns(values)
      return next
    case .throws:
      throw FakeError.daemonUnreachable
    }
  }
}

private enum FakeError: Error {
  case daemonUnreachable
  case buildFailed
  case noMoreClients
  case exhausted
}
