import Foundation
import HarnessMonitorCloudKit
import os

@MainActor
public final class NeedsMeCloudKitWriter {
  public static let shared = NeedsMeCloudKitWriter.makeShared()

  private let store: NeedsMeCloudKitStore
  private let debounceInterval: Duration
  private let isEnabled: Bool
  private let registerSubscription: @Sendable () async -> Void
  private var lastWrittenCount: Int?
  private var pendingTask: Task<Void, Never>?
  private let logger = Logger(
    subsystem: "io.harnessmonitor.kit",
    category: "needsme-cloudkit-writer"
  )

  public init(
    store: NeedsMeCloudKitStore = NeedsMeCloudKitStore(),
    debounceInterval: Duration = .seconds(5),
    isEnabled: Bool = true,
    registerSubscription: @escaping @Sendable () async -> Void = {
      await NeedsMeCloudKitSubscriptionService.shared.registerIfNeeded()
    }
  ) {
    self.store = store
    self.debounceInterval = debounceInterval
    self.isEnabled = isEnabled
    self.registerSubscription = registerSubscription
  }

  public static func makeShared(
    store: NeedsMeCloudKitStore = NeedsMeCloudKitStore(),
    debounceInterval: Duration = .seconds(5),
    isCloudKitAvailable: @escaping @Sendable () -> Bool = CloudKitContainer.hasCloudKitEntitlement,
    registerSubscription: @escaping @Sendable () async -> Void = {
      await NeedsMeCloudKitSubscriptionService.shared.registerIfNeeded()
    }
  ) -> NeedsMeCloudKitWriter {
    let isEnabled = isCloudKitAvailable()
    if !isEnabled {
      Logger(
        subsystem: "io.harnessmonitor.kit",
        category: "needsme-cloudkit-writer"
      ).info(
        "Needs-me CloudKit writer disabled because the app lacks the iCloud CloudKit entitlement."
      )
    }
    return NeedsMeCloudKitWriter(
      store: store,
      debounceInterval: debounceInterval,
      isEnabled: isEnabled,
      registerSubscription: registerSubscription
    )
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
      await registerSubscription()
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
