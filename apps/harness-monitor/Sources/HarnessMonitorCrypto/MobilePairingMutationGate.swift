public enum MobilePairingMutationGateError: Error, Equatable, Sendable {
  case reentrantMutation
}

/// Serializes non-reentrant mutations. Calling `perform` again on the same gate
/// from a gated operation throws instead of waiting on itself indefinitely.
public actor MobilePairingMutationGate {
  @TaskLocal private static var activeGateIDs: Set<ObjectIdentifier> = []

  private var locked = false
  private var waiters: [CheckedContinuation<Void, Never>] = []
  private var waiterCountObservers:
    [(minimumCount: Int, continuation: CheckedContinuation<Void, Never>)] = []

  public init() {}

  public func perform<Result: Sendable>(
    _ operation: @escaping @Sendable () async throws -> Result
  ) async throws -> Result {
    let gateID = ObjectIdentifier(self)
    guard !Self.activeGateIDs.contains(gateID) else {
      throw MobilePairingMutationGateError.reentrantMutation
    }
    await acquire()
    defer { release() }
    return try await Self.$activeGateIDs.withValue(Self.activeGateIDs.union([gateID])) {
      try await operation()
    }
  }

  func waitUntilQueuedOperations(atLeast minimumCount: Int) async {
    precondition(minimumCount > 0)
    guard waiters.count < minimumCount else {
      return
    }
    await withCheckedContinuation { continuation in
      waiterCountObservers.append((minimumCount, continuation))
    }
  }

  private func acquire() async {
    guard locked else {
      locked = true
      return
    }
    await withCheckedContinuation { continuation in
      waiters.append(continuation)
      resumeWaiterCountObservers()
    }
  }

  private func release() {
    guard !waiters.isEmpty else {
      locked = false
      return
    }
    waiters.removeFirst().resume()
  }

  private func resumeWaiterCountObservers() {
    var pendingObservers: [(minimumCount: Int, continuation: CheckedContinuation<Void, Never>)] = []
    for observer in waiterCountObservers {
      if waiters.count >= observer.minimumCount {
        observer.continuation.resume()
      } else {
        pendingObservers.append(observer)
      }
    }
    waiterCountObservers = pendingObservers
  }
}
