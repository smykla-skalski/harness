import Foundation
import HarnessMonitorKit
import os

/// Periodically resolves the needs-me count from the daemon and submits it to the
/// CloudKit writer, so the Apple Watch widget gets fresh data even when the user
/// is not currently viewing the Reviews dashboard. The route-view `onChange` path
/// stays in place as a fast reactive hop when Reviews IS open; this pump is the
/// safety net for every other case (app in background, different window route,
/// Reviews never opened this session).
@MainActor
public final class NeedsMeCountCloudKitPump {
  public static let shared = NeedsMeCountCloudKitPump()

  private let interval: Duration
  private let resolve: @Sendable () async throws -> Int
  private let submit: @MainActor (Int) -> Void
  private var task: Task<Void, Never>?
  private let logger = Logger(
    subsystem: "io.harnessmonitor.intents",
    category: "needsme-count-pump"
  )

  public convenience init() {
    self.init(
      interval: .seconds(300),
      resolve: { try await GetNeedsMeCountIntent().resolveCount() },
      submit: { count in NeedsMeCloudKitWriter.shared.submit(count: count) }
    )
  }

  init(
    interval: Duration,
    resolve: @escaping @Sendable () async throws -> Int,
    submit: @escaping @MainActor (Int) -> Void
  ) {
    self.interval = interval
    self.resolve = resolve
    self.submit = submit
  }

  public func start() {
    guard task == nil else { return }
    task = Task { [weak self] in
      while !Task.isCancelled, let self {
        await self.tick()
        do {
          try await Task.sleep(for: self.interval)
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

  @MainActor
  func tick() async {
    do {
      let count = try await resolve()
      submit(count)
      logger.info("Pump tick wrote count \(count, privacy: .public)")
    } catch {
      logger.info("Pump tick failed: \(error.localizedDescription, privacy: .public)")
    }
  }
}
