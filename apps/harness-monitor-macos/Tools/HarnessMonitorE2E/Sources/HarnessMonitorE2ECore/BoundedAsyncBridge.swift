import Foundation

/// Result of a bounded sync-to-async bridge call.
///
/// Either the underlying async operation finished within the deadline and
/// returned a value, or the deadline elapsed first and the bridge gave up
/// waiting. The original operation may still be running on its detached
/// `Task` when `.timedOut` is returned; the caller must treat the work as
/// abandoned and surface the stall to the user.
public enum BoundedAsyncResult<Value> {
  case completed(Value)
  case timedOut
}

/// Run an async closure on a detached `Task` and wait up to `timeout`
/// seconds for it from a synchronous context.
///
/// Mirrors the unbounded `runAsync` bridge used by `ScreenRecorder`, but
/// surfaces an explicit `.timedOut` instead of blocking the calling thread
/// forever when the underlying ScreenCaptureKit / async API stalls. The
/// detached task is not cancelled because callers (recorder bootstrap)
/// cannot safely abort partially-initialized SCStreams; instead they log
/// the stall and exit, and the host process owns final cleanup.
public func runAsyncBounded<Value: Sendable>(
  timeout: TimeInterval,
  _ operation: @escaping @Sendable () async throws -> Value
) throws -> BoundedAsyncResult<Value> {
  let semaphore = DispatchSemaphore(value: 0)
  let resultBox = BoundedTaskResultBox<Value>()
  Task {
    do {
      resultBox.set(.success(try await operation()))
    } catch {
      resultBox.set(.failure(error))
    }
    semaphore.signal()
  }
  let waitResult = semaphore.wait(timeout: .now() + timeout)
  switch waitResult {
  case .timedOut:
    return .timedOut
  case .success:
    guard let result = resultBox.consume() else {
      return .timedOut
    }
    return .completed(try result.get())
  }
}

private final class BoundedTaskResultBox<Value: Sendable>: @unchecked Sendable {
  private let lock = NSLock()
  private var result: Result<Value, Error>?

  func set(_ value: Result<Value, Error>) {
    lock.lock()
    defer { lock.unlock() }
    result = value
  }

  func consume() -> Result<Value, Error>? {
    lock.lock()
    defer { lock.unlock() }
    return result
  }
}
