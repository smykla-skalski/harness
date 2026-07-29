import SwiftUI
import Testing

@testable import HarnessMonitorUIPreviewable

extension TaskBoardOverviewBehaviorTests {
  @Test("Drag session decision reads dragged IDs only when the session starts")
  func dragSessionDecisionReadsDraggedIDsOnlyWhenSessionStarts() {
    #expect(
      taskBoardCardDragSessionDecision(for: .initial, isActionInFlight: false) == .processInitial
    )
    #expect(taskBoardCardDragSessionDecision(for: .active, isActionInFlight: false) == .ignore)
    #expect(taskBoardCardDragSessionDecision(for: .initial, isActionInFlight: true) == .ignore)
    #expect(taskBoardCardDragSessionDecision(for: .active, isActionInFlight: true) == .ignore)
  }

  @Test("Successful endings wait for transfer completion or the typed destination action")
  func successfulDragEndingsWaitForTheDestinationAction() {
    #expect(
      taskBoardCardDragSessionDecision(for: .ended(.move), isActionInFlight: false) == .ignore
    )
    #expect(
      taskBoardCardDragSessionDecision(for: .ended(.copy), isActionInFlight: true) == .ignore
    )
    #expect(
      taskBoardCardDragSessionDecision(for: .dataTransferCompleted, isActionInFlight: false)
        == .clear
    )
    #expect(
      taskBoardCardDragSessionDecision(for: .dataTransferCompleted, isActionInFlight: true)
        == .clear
    )
  }

  @Test("Cancelled and forbidden drags clear without a destination action")
  func unsuccessfulDragEndingsClearImmediately() {
    #expect(
      taskBoardCardDragSessionDecision(for: .ended(.cancel), isActionInFlight: false) == .clear
    )
    #expect(
      taskBoardCardDragSessionDecision(for: .ended(.forbidden), isActionInFlight: true) == .clear
    )
  }

  @Test("Only successful drag endings may commit the custom gap")
  func onlySuccessfulDragEndingsCommitTheCustomGap() {
    #expect(taskBoardCardDragSessionShouldCommitGap(for: .ended(.move)))
    #expect(taskBoardCardDragSessionShouldCommitGap(for: .ended(.copy)))
    #expect(!taskBoardCardDragSessionShouldCommitGap(for: .ended(.cancel)))
    #expect(!taskBoardCardDragSessionShouldCommitGap(for: .ended(.forbidden)))
    #expect(!taskBoardCardDragSessionShouldCommitGap(for: .dataTransferCompleted))
  }

  @Test("Lane drop target follows native session phases only while the lane is valid")
  func laneDropTargetFollowsNativeSessionPhasesOnlyWhileValid() {
    #expect(taskBoardLaneIsDropTargeted(for: .entering, isCandidate: true))
    #expect(taskBoardLaneIsDropTargeted(for: .active, isCandidate: true))
    #expect(!taskBoardLaneIsDropTargeted(for: .entering, isCandidate: false))
    #expect(!taskBoardLaneIsDropTargeted(for: .active, isCandidate: false))
  }

  @Test("Lane drop target clears on every terminal native session phase")
  func laneDropTargetClearsOnEveryTerminalNativeSessionPhase() {
    #expect(!taskBoardLaneIsDropTargeted(for: .exiting, isCandidate: true))
    #expect(!taskBoardLaneIsDropTargeted(for: .ended(.move), isCandidate: true))
    #expect(!taskBoardLaneIsDropTargeted(for: .ended(.cancel), isCandidate: true))
    #expect(!taskBoardLaneIsDropTargeted(for: .dataTransferCompleted, isCandidate: true))
  }

  @Test("Custom gap waits for the pushed final card midpoint")
  func customGapWaitsForThePushedFinalCardMidpoint() {
    let midpoints: [CGFloat] = [500]

    #expect(
      taskBoardCardGapInsertionIndex(
        midpoints: midpoints,
        currentIndex: 0,
        pointerY: 401,
        gapHeight: 100
      ) == 0
    )
    #expect(
      taskBoardCardGapInsertionIndex(
        midpoints: midpoints,
        currentIndex: 0,
        pointerY: 399,
        gapHeight: 100
      ) == 1
    )
  }

  @Test("Custom gap translates the pointer after its List scrolls")
  func customGapTranslatesThePointerAfterItsListScrolls() {
    #expect(
      taskBoardCardGapPointerYInSnapshotSpace(
        pointerY: 350,
        snapshotReferenceY: 100,
        currentReferenceY: 50
      ) == 400
    )
  }

  @Test("Custom gap parks the lifted row in its original source slot")
  func customGapParksTheLiftedRowInItsOriginalSourceSlot() {
    #expect(taskBoardCardGapSourceTargetIndex(sourceIndex: 0, sourceCount: 1) == 0)
    #expect(taskBoardCardGapSourceTargetIndex(sourceIndex: 2, sourceCount: 3) == 2)
    #expect(taskBoardCardGapSourceTargetIndex(sourceIndex: 4, sourceCount: 3) == 2)
  }

  @Test("Custom gap owns stable isolated state for each lane")
  @MainActor
  func customGapOwnsStableIsolatedStateForEachLane() {
    let model = TaskBoardCardGapModel()
    let firstTodoState = model.state(for: .todo)
    let secondTodoState = model.state(for: .todo)
    let planningState = model.state(for: .planning)

    #expect(firstTodoState === secondTodoState)
    #expect(firstTodoState !== planningState)
  }

  @Test("Ending a custom gap releases its callback even before a drag starts")
  @MainActor
  func endingCustomGapReleasesItsCallback() {
    let model = TaskBoardCardGapModel()
    model.onDragReleased = {}

    model.end()

    #expect(model.onDragReleased == nil)
  }

  @Test("Drag runtime isolates one active lane highlight")
  @MainActor
  func dragRuntimeIsolatesOneActiveLaneHighlight() {
    let runtime = TaskBoardCardDragRuntime()
    let todoHighlight = runtime.highlightState(for: .todo)
    let planningHighlight = runtime.highlightState(for: .planning)

    runtime.begin(
      cardIDs: [.api("task-1")],
      candidateLanes: [.todo, .planning]
    )
    runtime.setTargeted(true, lane: .todo)
    #expect(todoHighlight.isTargeted)
    #expect(!planningHighlight.isTargeted)

    runtime.setTargeted(true, lane: .planning)
    #expect(!todoHighlight.isTargeted)
    #expect(planningHighlight.isTargeted)

    runtime.clear()
    #expect(!todoHighlight.isTargeted)
    #expect(!planningHighlight.isTargeted)
  }

  @Test("Drag runtime rejects highlights outside the drop plan")
  @MainActor
  func dragRuntimeRejectsHighlightsOutsideTheDropPlan() {
    let runtime = TaskBoardCardDragRuntime()
    let failedHighlight = runtime.highlightState(for: .failed)

    runtime.begin(
      cardIDs: [.api("task-1")],
      candidateLanes: [.planning]
    )
    runtime.setTargeted(true, lane: .failed)

    #expect(!failedHighlight.isTargeted)
    #expect(!runtime.accepts(.failed))
  }

  @Test("Drop session trace preserves its trajectory without retaining the session")
  func dropSessionTracePreservesTrajectory() {
    var trace = TaskBoardDropSessionTrace()

    trace.record(
      sessionID: "abc",
      phase: "entering",
      location: CGPoint(x: 210, y: 80),
      destinationSize: CGSize(width: 420, height: 704),
      elapsedMilliseconds: 40,
      itemsCount: 1,
      suggestedOperationsRawValue: 3
    )
    trace.record(
      sessionID: "abc",
      phase: "active",
      location: CGPoint(x: 190, y: 120),
      destinationSize: CGSize(width: 420, height: 704),
      elapsedMilliseconds: 55,
      itemsCount: 1,
      suggestedOperationsRawValue: 3
    )
    trace.record(
      sessionID: "abc",
      phase: "active",
      location: CGPoint(x: 230, y: 100),
      destinationSize: CGSize(width: 420, height: 704),
      elapsedMilliseconds: 72,
      itemsCount: 1,
      suggestedOperationsRawValue: 3
    )

    #expect(trace.phaseCounts == ["active": 2, "entering": 1])
    #expect(trace.firstLocation == CGPoint(x: 210, y: 80))
    #expect(trace.lastLocation == CGPoint(x: 230, y: 100))
    #expect(trace.minimumLocation == CGPoint(x: 190, y: 80))
    #expect(trace.maximumLocation == CGPoint(x: 230, y: 120))
    #expect(trace.firstActiveElapsedMilliseconds == 55)
    #expect(trace.lastElapsedMilliseconds == 72)
    #expect(trace.itemsCount == 1)
    #expect(trace.suggestedOperationsRawValue == 3)
    #expect(trace.summary.contains("bounds=190,80...230,120"))
  }

}
