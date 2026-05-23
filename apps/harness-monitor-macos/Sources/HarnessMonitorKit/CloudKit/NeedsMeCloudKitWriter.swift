import Foundation
import HarnessMonitorCloudKit
import os

@MainActor
public final class NeedsMeCloudKitWriter {
  // Shared singleton is disabled until the macOS app bundle gains the iCloud
  // entitlement + the CloudKit container is registered in the Apple Developer
  // portal (Phase E of the Watch widget plan). Constructing `CKContainer` from
  // a process without `com.apple.developer.icloud-services` entitlements aborts
  // inside CloudKit (EXC_BREAKPOINT in `CKContainer` init). Flip the flag to
  // `true` once Phase E has landed.
  public static let shared = NeedsMeCloudKitWriter(isEnabled: false)

  private let store: NeedsMeCloudKitStore
  private let debounceInterval: Duration
  private let isEnabled: Bool
  private var lastWrittenCount: Int?
  private var pendingTask: Task<Void, Never>?
  private let logger = Logger(
    subsystem: "io.harnessmonitor.kit",
    category: "needsme-cloudkit-writer"
  )

  public init(
    store: NeedsMeCloudKitStore = NeedsMeCloudKitStore(),
    debounceInterval: Duration = .seconds(5),
    isEnabled: Bool = true
  ) {
    self.store = store
    self.debounceInterval = debounceInterval
    self.isEnabled = isEnabled
  }

  public func submit(count: Int) {
    guard isEnabled else {
      return
    }
    if lastWrittenCount == count {
      return
    }
    pendingTask?.cancel()
    let interval = debounceInterval
    let pendingCount = count
    pendingTask = Task { [weak self] in
      do {
        try await Task.sleep(for: interval)
      } catch {
        return
      }
      await self?.performWrite(count: pendingCount)
    }
  }

  public func flush() async {
    _ = await pendingTask?.value
  }

  private func performWrite(count: Int) async {
    do {
      _ = try await store.upsert(count: Int64(count), updatedAt: Date())
      lastWrittenCount = count
      logger.info("Wrote needs-me count \(count, privacy: .public) to CloudKit")
    } catch NeedsMeCloudKitError.notAuthenticated {
      logger.info("Skipped CloudKit write (user not signed into iCloud)")
    } catch let error as NeedsMeCloudKitError {
      logger.warning("CloudKit upsert failed: \(String(describing: error), privacy: .public)")
    } catch {
      logger.warning(
        "Unexpected CloudKit upsert failure: \(error.localizedDescription, privacy: .public)")
    }
  }
}
