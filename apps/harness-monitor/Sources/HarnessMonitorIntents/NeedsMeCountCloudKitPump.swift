import Foundation
import HarnessMonitorKit
import os

/// Periodically resolves the needs-me count from the daemon and submits it to the
/// CloudKit writer, so the Apple Watch widget gets fresh data even when the user
/// is not currently viewing the Reviews dashboard. The route-view `onChange` path
/// stays in place as a fast reactive hop when Reviews IS open; this pump is the
/// safety net for every other case (app in background, different window route,
/// Reviews never opened this session).
///
/// The first tick at launch can race the daemon's manifest bootstrap. When `tick`
/// fails the next sleep uses an exponential backoff (capped at `maxBackoff`)
/// instead of the full 5-minute steady-state interval, so the Watch never gets
/// stranded for the full window because of a startup race.
@MainActor
public final class NeedsMeCountCloudKitPump {
  public static let shared = NeedsMeCountCloudKitPump()

  private let interval: Duration
  private let initialBackoff: Duration
  private let maxBackoff: Duration
  private let resolve: @Sendable () async throws -> Int
  private let submit: @MainActor (Int) -> Void
  private var task: Task<Void, Never>?
  private var currentBackoff: Duration
  private let logger = Logger(
    subsystem: "io.harnessmonitor.intents",
    category: "needsme-count-pump"
  )

  public convenience init() {
    let resolver = DaemonCountResolver()
    self.init(
      interval: .seconds(300),
      initialBackoff: .seconds(2),
      maxBackoff: .seconds(60),
      resolve: { try await resolver.resolve() },
      submit: { count in NeedsMeCloudKitWriter.shared.submit(count: count) }
    )
  }

  init(
    interval: Duration,
    initialBackoff: Duration = .seconds(2),
    maxBackoff: Duration = .seconds(60),
    resolve: @escaping @Sendable () async throws -> Int,
    submit: @escaping @MainActor (Int) -> Void
  ) {
    self.interval = interval
    self.initialBackoff = initialBackoff
    self.maxBackoff = maxBackoff
    self.resolve = resolve
    self.submit = submit
    self.currentBackoff = initialBackoff
  }

  public func start() {
    guard task == nil else { return }
    currentBackoff = initialBackoff
    task = Task { [weak self] in
      while !Task.isCancelled, let self {
        let succeeded = await self.tick()
        let delay = self.advance(after: succeeded)
        do {
          try await Task.sleep(for: delay)
        } catch {
          return
        }
      }
    }
  }

  public func stop() {
    task?.cancel()
    task = nil
  }

  @discardableResult
  func tick() async -> Bool {
    do {
      let count = try await resolve()
      submit(count)
      logger.info("Pump tick wrote count \(count, privacy: .public)")
      return true
    } catch {
      logger.info("Pump tick failed: \(error.localizedDescription, privacy: .public)")
      return false
    }
  }

  func advance(after succeeded: Bool) -> Duration {
    if succeeded {
      currentBackoff = initialBackoff
      return interval
    }
    let delay = currentBackoff
    currentBackoff = min(currentBackoff * 2, maxBackoff)
    return delay
  }
}
