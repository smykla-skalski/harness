import HarnessMonitorKit
import Testing

@testable import HarnessMonitorUIPreviewable

@Suite("Task board lane reveal coordinator")
@MainActor
struct TaskBoardLaneRevealCoordinatorTests {
  @Test("Requests retain their card, lane, and anchor")
  func requestsRetainTheirDestination() {
    let coordinator = TaskBoardLaneRevealCoordinator()

    let topCard = TaskBoardCardID.api("top-card")
    let topOrder = [TaskBoardCardID.api("todo-a"), topCard]
    let topRequest = coordinator.request(
      cardID: topCard,
      in: .todo,
      anchor: .top,
      priorDestinationCardIDs: topOrder
    )
    #expect(topRequest.cardID == topCard)
    #expect(topRequest.lane == .todo)
    #expect(topRequest.anchor == .top)
    #expect(topRequest.priorDestinationCardIDs == topOrder)

    let minimalCard = TaskBoardCardID.api("minimal-card")
    let minimalRequest = coordinator.request(
      cardID: minimalCard,
      in: .planning,
      anchor: .minimal,
      priorDestinationCardIDs: []
    )
    #expect(minimalRequest.cardID == minimalCard)
    #expect(minimalRequest.lane == .planning)
    #expect(minimalRequest.anchor == .minimal)

    let bottomCard = TaskBoardCardID.inbox(sessionID: "session-a", taskID: "bottom-card")
    let bottomRequest = coordinator.request(
      cardID: bottomCard,
      in: .humanRequired,
      anchor: .bottom,
      priorDestinationCardIDs: [bottomCard]
    )
    #expect(bottomRequest.cardID == bottomCard)
    #expect(bottomRequest.lane == .humanRequired)
    #expect(bottomRequest.anchor == .bottom)
  }

  @Test("Repeated identical requests receive increasing generations")
  func repeatedRequestsReceiveIncreasingGenerations() {
    let coordinator = TaskBoardLaneRevealCoordinator()
    let cardID = TaskBoardCardID.api("repeated-card")

    let first = coordinator.request(
      cardID: cardID,
      in: .todo,
      anchor: .minimal,
      priorDestinationCardIDs: [cardID]
    )
    let second = coordinator.request(
      cardID: cardID,
      in: .todo,
      anchor: .minimal,
      priorDestinationCardIDs: [cardID]
    )

    #expect(second.generation > first.generation)
    #expect(coordinator.pendingRequest?.generation == second.generation)
  }

  @Test("A request waits for the destination order containing its exact card to change")
  func requestRequiresChangedDestinationOrder() {
    let coordinator = TaskBoardLaneRevealCoordinator()
    let requestedCard = TaskBoardCardID.api("requested-card")
    let otherCard = TaskBoardCardID.api("other-card")
    let priorOrder = [requestedCard, otherCard]
    let request = coordinator.request(
      cardID: requestedCard,
      in: .planning,
      anchor: .minimal,
      priorDestinationCardIDs: priorOrder
    )

    #expect(
      coordinator.actionableRequest(
        in: .planning,
        orderedCardIDs: []
      ) == nil
    )
    #expect(
      coordinator.actionableRequest(
        in: .planning,
        orderedCardIDs: [otherCard]
      ) == nil
    )
    #expect(
      coordinator.actionableRequest(
        in: .todo,
        orderedCardIDs: [otherCard, requestedCard]
      ) == nil
    )
    #expect(
      coordinator.actionableRequest(
        in: .planning,
        orderedCardIDs: priorOrder
      ) == nil
    )

    let actionable = coordinator.actionableRequest(
      in: .planning,
      orderedCardIDs: [otherCard, requestedCard]
    )
    #expect(actionable?.generation == request.generation)
    #expect(actionable?.cardID == requestedCard)
  }

  @Test("A cross-lane request waits until the card appears in the destination order")
  func crossLaneRequestWaitsForCardAppearance() {
    let coordinator = TaskBoardLaneRevealCoordinator()
    let requestedCard = TaskBoardCardID.api("incoming-card")
    let existingCard = TaskBoardCardID.api("existing-card")
    let request = coordinator.request(
      cardID: requestedCard,
      in: .planning,
      anchor: .minimal,
      priorDestinationCardIDs: [existingCard]
    )

    #expect(
      coordinator.actionableRequest(
        in: .planning,
        orderedCardIDs: [existingCard]
      ) == nil
    )
    #expect(
      coordinator.actionableRequest(
        in: .planning,
        orderedCardIDs: [existingCard, requestedCard]
      ) == request
    )
  }

  @Test("Consuming an old request preserves a newer request")
  func consumeClearsOnlyMatchingGeneration() {
    let coordinator = TaskBoardLaneRevealCoordinator()
    let oldRequest = coordinator.request(
      cardID: .api("old-card"),
      in: .todo,
      anchor: .top,
      priorDestinationCardIDs: []
    )
    let newRequest = coordinator.request(
      cardID: .api("new-card"),
      in: .inProgress,
      anchor: .bottom,
      priorDestinationCardIDs: []
    )

    coordinator.consume(oldRequest)
    #expect(coordinator.pendingRequest?.generation == newRequest.generation)

    coordinator.consume(newRequest)
    #expect(coordinator.pendingRequest == nil)
  }

  @Test("Retry preserves the destination and gives the task a fresh identity")
  func retryPreservesDestinationWithFreshGeneration() throws {
    let coordinator = TaskBoardLaneRevealCoordinator()
    let cardID = TaskBoardCardID.api("retry-card")
    let priorOrder = [TaskBoardCardID.api("existing-card")]
    let request = coordinator.request(
      cardID: cardID,
      in: .planning,
      anchor: .bottom,
      priorDestinationCardIDs: priorOrder
    )

    let retried = try #require(coordinator.retry(request))

    #expect(retried.generation > request.generation)
    #expect(retried.retryAttempt == 1)
    #expect(retried.cardID == cardID)
    #expect(retried.lane == .planning)
    #expect(retried.anchor == .bottom)
    #expect(retried.priorDestinationCardIDs == priorOrder)
    #expect(coordinator.isPending(retried))
    #expect(!coordinator.isPending(request))
    #expect(
      coordinator.actionableRequest(
        in: .planning,
        orderedCardIDs: [priorOrder[0], cardID]
      ) == retried
    )
  }

  @Test("Retry stops after a bounded number of layout attempts")
  func retryHasABoundedAttemptCount() throws {
    let coordinator = TaskBoardLaneRevealCoordinator()
    let request = coordinator.request(
      cardID: .api("bounded-card"),
      in: .todo,
      anchor: .minimal,
      priorDestinationCardIDs: []
    )
    let firstRetry = try #require(coordinator.retry(request))
    let secondRetry = try #require(coordinator.retry(firstRetry))

    #expect(secondRetry.retryAttempt == 2)
    #expect(coordinator.retry(secondRetry) == nil)
    #expect(coordinator.isPending(secondRetry))
  }

  @Test("Retrying a stale request preserves the newer reveal")
  func retryRejectsStaleRequest() {
    let coordinator = TaskBoardLaneRevealCoordinator()
    let stale = coordinator.request(
      cardID: .api("stale-card"),
      in: .todo,
      anchor: .top,
      priorDestinationCardIDs: []
    )
    let current = coordinator.request(
      cardID: .api("current-card"),
      in: .testing,
      anchor: .minimal,
      priorDestinationCardIDs: []
    )

    #expect(coordinator.retry(stale) == nil)
    #expect(coordinator.pendingRequest == current)
    #expect(coordinator.isPending(current))
  }
}
