import Foundation
import Testing

@testable import HarnessMonitorKit

@MainActor
@Suite("Harness Monitor working-copy progress fan-out")
struct HarnessMonitorStoreWorkingCopyProgressTests {
  private func advanced(
    repo: String = "acme/widgets",
    done: UInt64 = 40
  ) -> TaskBoardWorkingCopyProgress {
    TaskBoardWorkingCopyProgress(
      kind: .advanced,
      repoFullName: repo,
      phase: "Receiving objects",
      done: done,
      total: 100
    )
  }

  @Test("A per-repo subscriber receives its own repository's progress")
  func aPerRepoSubscriberReceivesItsOwnProgress() async {
    let store = await makeBootstrappedStore()
    let stream = store.observeWorkingCopyProgress(repoFullName: "acme/widgets")
    var iterator = stream.makeAsyncIterator()

    store.applyWorkingCopyProgress(advanced())

    let received = await iterator.next()
    #expect(received?.repoFullName == "acme/widgets")
    #expect(received?.done == 40)
  }

  @Test("A per-repo subscriber is not woken by another repository")
  func aPerRepoSubscriberIsNotWokenByAnotherRepository() async {
    let store = await makeBootstrappedStore()
    let stream = store.observeWorkingCopyProgress(repoFullName: "acme/widgets")
    var iterator = stream.makeAsyncIterator()

    store.applyWorkingCopyProgress(advanced(repo: "acme/gadgets"))
    store.applyWorkingCopyProgress(advanced(repo: "acme/widgets", done: 55))

    // The gadgets event must not be what arrives first.
    let received = await iterator.next()
    #expect(received?.repoFullName == "acme/widgets")
    #expect(received?.done == 55)
  }

  @Test("A catch-all subscriber receives every repository's progress")
  func aCatchAllSubscriberReceivesEveryRepository() async {
    let store = await makeBootstrappedStore()
    let stream = store.observeAllWorkingCopyProgress()
    var iterator = stream.makeAsyncIterator()

    store.applyWorkingCopyProgress(advanced(repo: "acme/gadgets", done: 3))

    let received = await iterator.next()
    #expect(received?.repoFullName == "acme/gadgets")
  }

  @Test("Dropping a subscription unregisters it")
  func droppingASubscriptionUnregistersIt() async {
    let store = await makeBootstrappedStore()
    do {
      let stream = store.observeWorkingCopyProgress(repoFullName: "acme/widgets")
      _ = stream.makeAsyncIterator()
      #expect(store.workingCopyProgressSubscriberCount(repoFullName: "acme/widgets") == 1)
    }

    // `onTermination` hops to the MainActor, so let that hop land first.
    for _ in 0..<1_000 {
      if store.workingCopyProgressSubscriberCount(repoFullName: "acme/widgets") == 0 {
        break
      }
      await Task.yield()
    }

    #expect(store.workingCopyProgressSubscriberCount(repoFullName: "acme/widgets") == 0)
  }
}
