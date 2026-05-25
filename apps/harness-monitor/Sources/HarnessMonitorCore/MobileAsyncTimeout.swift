import Foundation

public enum MobileAsyncTimeout {
  public static func run<Value: Sendable>(
    timeout: Duration,
    timeoutError: @escaping @Sendable () -> any Error,
    operation: @escaping @Sendable () async throws -> Value
  ) async throws -> Value {
    let state = MobileAsyncTimeoutState<Value>()
    let operationTask = Task.detached {
      do {
        try Task.checkCancellation()
        let value = try await operation()
        state.complete(.success(value))
      } catch {
        state.complete(.failure(error))
      }
    }
    let timeoutTask = Task.detached {
      do {
        try await Task.sleep(for: timeout)
        operationTask.cancel()
        state.complete(.failure(timeoutError()))
      } catch {
        state.complete(.failure(error))
      }
    }

    return try await withTaskCancellationHandler {
      defer {
        operationTask.cancel()
        timeoutTask.cancel()
      }
      return try await state.wait()
    } onCancel: {
      operationTask.cancel()
      timeoutTask.cancel()
      state.complete(.failure(CancellationError()))
    }
  }
}

public struct MobileMirrorRefreshTimeout: Error, LocalizedError, Equatable, Sendable {
  public init() {}

  public var errorDescription: String? {
    "Timed out fetching the encrypted mirror. Showing the last cached state."
  }
}

private final class MobileAsyncTimeoutState<Value: Sendable>: @unchecked Sendable {
  private let lock = NSLock()
  private var result: Result<Value, any Error>?
  private var continuation: CheckedContinuation<Value, any Error>?

  func wait() async throws -> Value {
    try await withCheckedThrowingContinuation { continuation in
      let resultToResume: Result<Value, any Error>?
      lock.lock()
      if let result {
        resultToResume = result
      } else {
        resultToResume = nil
        self.continuation = continuation
      }
      lock.unlock()

      if let resultToResume {
        continuation.resume(with: resultToResume)
      }
    }
  }

  func complete(_ result: Result<Value, any Error>) {
    let continuationToResume: CheckedContinuation<Value, any Error>?
    lock.lock()
    guard self.result == nil else {
      lock.unlock()
      return
    }
    self.result = result
    continuationToResume = continuation
    continuation = nil
    lock.unlock()

    continuationToResume?.resume(with: result)
  }
}
