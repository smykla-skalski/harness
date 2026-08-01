import Testing

@testable import HarnessMonitorUIPreviewable

@MainActor
extension TaskBoardOverviewBehaviorTests {
  @Test("Drop deduper suppresses duplicate successful drops until reset")
  func dropDeduperSuppressesDuplicateSuccessfulDropsUntilReset() {
    var deduper = TaskBoardDropDeduper<String>()
    var moves = 0

    #expect(
      deduper.perform("board-1|running") {
        moves += 1
        return true
      }
    )
    #expect(
      deduper.perform("board-1|running") {
        moves += 1
        return true
      }
    )
    #expect(moves == 1)

    deduper.reset()

    #expect(
      deduper.perform("board-1|running") {
        moves += 1
        return true
      }
    )
    #expect(moves == 2)
  }

  @Test("Drop deduper retries a key after an unsuccessful move")
  func dropDeduperRetriesKeyAfterUnsuccessfulMove() {
    var deduper = TaskBoardDropDeduper<String>()
    var attempts = 0

    #expect(
      !deduper.perform("board-1|running") {
        attempts += 1
        return false
      }
    )
    #expect(
      deduper.perform("board-1|running") {
        attempts += 1
        return true
      }
    )
    #expect(attempts == 2)
  }
}
