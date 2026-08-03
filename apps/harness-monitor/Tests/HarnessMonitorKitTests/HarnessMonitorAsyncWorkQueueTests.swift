import Darwin
import Foundation
import Testing

@testable import HarnessMonitorKit

@Suite("Harness Monitor async work queue")
struct HarnessMonitorAsyncWorkQueueTests {
  @Test("default worker count uses the active processor count")
  func defaultWorkerCountUsesTheActiveProcessorCount() {
    let queue = HarnessMonitorAsyncWorkQueue()

    #expect(queue.workerCount == max(1, ProcessInfo.processInfo.activeProcessorCount))
  }

  @Test("queue drains independent jobs concurrently across workers")
  func queueDrainsIndependentJobsConcurrentlyAcrossWorkers() async {
    let workerCount = min(4, max(2, ProcessInfo.processInfo.activeProcessorCount))
    let jobCount = workerCount * 2
    let queue = HarnessMonitorAsyncWorkQueue(workerCount: workerCount)
    let tracker = AsyncWorkQueueConcurrencyTracker()

    for index in 0..<jobCount {
      await queue.enqueue(
        HarnessMonitorAsyncWorkQueue.WorkItem(title: "test job \(index)") {
          await tracker.started()
          try? await Task.sleep(for: .milliseconds(50))
          await tracker.finished()
        }
      )
    }

    let snapshot = await waitForQueueSnapshot(
      tracker: tracker,
      expectedCompletions: jobCount
    )

    #expect(snapshot.completed == jobCount)
    #expect(snapshot.maximumActive > 1)
    #expect(snapshot.maximumActive <= workerCount)
  }

  @Test("queued work never starts on the main thread")
  func queuedWorkNeverStartsOnTheMainThread() async {
    let queue = HarnessMonitorAsyncWorkQueue(workerCount: 1)
    let recorder = AsyncWorkQueueThreadRecorder()

    await queue.enqueue(
      HarnessMonitorAsyncWorkQueue.WorkItem(title: "thread check") {
        await recorder.record(isMainThread: pthread_main_np() == 1)
      }
    )

    var recorded = await recorder.value()
    var attempts = 0
    while recorded == nil && attempts < 200 {
      try? await Task.sleep(for: .milliseconds(10))
      recorded = await recorder.value()
      attempts += 1
    }
    #expect(recorded == false)
  }

  private func waitForQueueSnapshot(
    tracker: AsyncWorkQueueConcurrencyTracker,
    expectedCompletions: Int
  ) async -> AsyncWorkQueueConcurrencyTracker.Snapshot {
    var snapshot = await tracker.snapshot()
    var attempts = 0
    while snapshot.completed < expectedCompletions && attempts < 200 {
      try? await Task.sleep(for: .milliseconds(10))
      snapshot = await tracker.snapshot()
      attempts += 1
    }
    return snapshot
  }
}

private actor AsyncWorkQueueThreadRecorder {
  private var isMainThread: Bool?

  func record(isMainThread: Bool) {
    self.isMainThread = isMainThread
  }

  func value() -> Bool? {
    isMainThread
  }
}

private actor AsyncWorkQueueConcurrencyTracker {
  struct Snapshot: Sendable {
    let completed: Int
    let maximumActive: Int
  }

  private var active = 0
  private var completed = 0
  private var maximumActive = 0

  func started() {
    active += 1
    maximumActive = max(maximumActive, active)
  }

  func finished() {
    active -= 1
    completed += 1
  }

  func snapshot() -> Snapshot {
    Snapshot(completed: completed, maximumActive: maximumActive)
  }
}
