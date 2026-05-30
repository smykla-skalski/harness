import Foundation

/// Process-wide async work queue for UI-triggered work that must not block the
/// initiating view task. The queue starts one detached worker per active CPU
/// core as demand appears, so independent jobs can use the full system executor
/// instead of serializing behind a route-local task.
public actor HarnessMonitorAsyncWorkQueue {
  public static let shared = HarnessMonitorAsyncWorkQueue()

  nonisolated public let workerCount: Int

  private var pendingItems: [WorkItem] = []
  private var pendingHeadIndex = 0
  private var activeWorkerCount = 0

  public init(workerCount: Int = ProcessInfo.processInfo.activeProcessorCount) {
    self.workerCount = max(1, workerCount)
  }

  nonisolated public func submit(_ item: WorkItem) {
    Task {
      await enqueue(item)
    }
  }

  public func enqueue(_ item: WorkItem) {
    pendingItems.append(item)
    startAvailableWorkers()
  }

  private func startAvailableWorkers() {
    while activeWorkerCount < workerCount && hasPendingItems {
      activeWorkerCount += 1
      Task.detached(priority: .userInitiated) {
        await self.runWorker()
      }
    }
  }

  private func runWorker() async {
    while let item = nextItemOrStopWorker() {
      await item.operation()
    }
  }

  private func nextItemOrStopWorker() -> WorkItem? {
    guard hasPendingItems else {
      activeWorkerCount -= 1
      compactPendingStorageIfNeeded()
      return nil
    }
    let item = pendingItems[pendingHeadIndex]
    pendingHeadIndex += 1
    compactPendingStorageIfNeeded()
    return item
  }

  private var hasPendingItems: Bool {
    pendingHeadIndex < pendingItems.count
  }

  private func compactPendingStorageIfNeeded() {
    guard pendingHeadIndex > 0 else {
      return
    }
    if pendingHeadIndex == pendingItems.count {
      pendingItems.removeAll(keepingCapacity: true)
      pendingHeadIndex = 0
    } else if pendingHeadIndex > 64 && pendingHeadIndex * 2 >= pendingItems.count {
      pendingItems.removeFirst(pendingHeadIndex)
      pendingHeadIndex = 0
    }
  }
}

extension HarnessMonitorAsyncWorkQueue {
  public struct WorkItem: Sendable, Identifiable {
    public let id: UUID
    public let title: String
    public let operation: @Sendable () async -> Void

    public init(
      id: UUID = UUID(),
      title: String,
      operation: @escaping @Sendable () async -> Void
    ) {
      self.id = id
      self.title = title
      self.operation = operation
    }
  }
}
