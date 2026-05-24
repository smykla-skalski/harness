import Foundation

actor SupervisorOneShotGate<Value: Sendable> {
  private var value: Value?
  private var waiters: [CheckedContinuation<Value, Never>] = []

  func wait() async -> Value {
    if let value {
      return value
    }
    return await withCheckedContinuation { continuation in
      waiters.append(continuation)
    }
  }

  func finish(_ value: Value) {
    guard self.value == nil else {
      return
    }
    self.value = value
    let waiters = waiters
    self.waiters.removeAll()
    for waiter in waiters {
      waiter.resume(returning: value)
    }
  }
}
