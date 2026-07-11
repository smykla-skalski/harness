public actor MobilePairingMutationGate {
  private var locked = false
  private var waiters: [CheckedContinuation<Void, Never>] = []

  public init() {}

  public func perform<Result: Sendable>(
    _ operation: @escaping @Sendable () async throws -> Result
  ) async throws -> Result {
    await acquire()
    defer { release() }
    return try await operation()
  }

  private func acquire() async {
    guard locked else {
      locked = true
      return
    }
    await withCheckedContinuation { continuation in
      waiters.append(continuation)
    }
  }

  private func release() {
    guard !waiters.isEmpty else {
      locked = false
      return
    }
    waiters.removeFirst().resume()
  }
}
