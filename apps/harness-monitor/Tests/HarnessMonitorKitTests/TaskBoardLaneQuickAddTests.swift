import Testing

@testable import HarnessMonitorKit
@testable import HarnessMonitorUIPreviewable

@Suite("Task board lane quick add")
struct TaskBoardLaneQuickAddTests {
  @Test("Only the umbrella lane refuses a typed-in task")
  func onlyUmbrellaLaneRefusesTypedInTask() {
    let refusing = TaskBoardInboxLane.allCases.filter { !$0.acceptsQuickAddedTask }

    #expect(refusing == [.umbrella])
  }

  @Test("A lane accepts a typed-in task exactly when it stands for a status")
  func laneAcceptsTypedInTaskExactlyWhenItStandsForAStatus() {
    for lane in TaskBoardInboxLane.allCases {
      #expect(lane.acceptsQuickAddedTask == (lane.taskBoardDropStatus != nil))
    }
  }

  @Test("A quick add lands in the lane it was typed into")
  func quickAddLandsInTheLaneItWasTypedInto() throws {
    for lane in TaskBoardInboxLane.allCases where lane.acceptsQuickAddedTask {
      let request = try #require(TaskBoardLaneQuickAdd.request(title: "Ship it", lane: lane))

      #expect(request.status == lane.taskBoardDropStatus?.canonicalPersistedStatus)
      #expect(request.title == "Ship it")
    }
  }

  /// The status is what suppresses automatic triage placement daemon-side, so a
  /// request that omitted it would let triage move the item straight back out
  /// of the lane someone just typed it into.
  @Test("A quick add always names its status rather than leaving it to triage")
  func quickAddAlwaysNamesItsStatus() throws {
    let request = try #require(TaskBoardLaneQuickAdd.request(title: "Ship it", lane: .inbox))

    #expect(request.status != nil)
  }

  @Test("A quick add trims the typed title")
  func quickAddTrimsTheTypedTitle() throws {
    let request = try #require(
      TaskBoardLaneQuickAdd.request(title: "  Ship it  ", lane: .todo)
    )

    #expect(request.title == "Ship it")
  }

  @Test("A blank title creates nothing")
  func blankTitleCreatesNothing() {
    #expect(TaskBoardLaneQuickAdd.request(title: "", lane: .todo) == nil)
    #expect(TaskBoardLaneQuickAdd.request(title: "   \n ", lane: .todo) == nil)
  }

  @Test("A lane that refuses typed-in tasks creates nothing")
  func laneThatRefusesTypedInTasksCreatesNothing() {
    #expect(TaskBoardLaneQuickAdd.request(title: "Ship it", lane: .umbrella) == nil)
  }

  @Test("A quick add carries the same defaults the full form starts from")
  func quickAddCarriesTheSameDefaultsTheFullFormStartsFrom() throws {
    let request = try #require(TaskBoardLaneQuickAdd.request(title: "Ship it", lane: .todo))
    let formDefaults = TaskBoardItemEditorDraft()

    #expect(request.priority == formDefaults.priority)
    #expect(request.agentMode == formDefaults.agentMode)
    #expect(request.body.isEmpty)
    #expect(request.tags.isEmpty)
  }

  @MainActor
  @Test("An open quick add hands the board's keystrokes to the field")
  func openQuickAddHandsBoardKeystrokesToTheField() {
    let model = TaskBoardCardSelectionModel()

    #expect(model.acceptsBoardShortcuts)

    model.beginQuickAdd(in: .todo)

    #expect(model.quickAddLane == .todo)
    #expect(!model.acceptsBoardShortcuts)

    model.endQuickAdd(in: .todo)

    #expect(model.quickAddLane == nil)
    #expect(model.acceptsBoardShortcuts)
  }

  /// Two lanes' fields cannot be open at once, and the lane that just lost the
  /// field must not close the one that took it.
  @MainActor
  @Test("Opening a second lane's field closes the first without it closing the second")
  func openingSecondLaneFieldClosesTheFirstOnly() {
    let model = TaskBoardCardSelectionModel()

    model.beginQuickAdd(in: .todo)
    model.beginQuickAdd(in: .inbox)
    model.endQuickAdd(in: .todo)

    #expect(model.quickAddLane == .inbox)
  }

  @MainActor
  @Test("Opening the full form closes an open quick add")
  func openingFullFormClosesOpenQuickAdd() {
    let model = TaskBoardCardSelectionModel()

    model.beginQuickAdd(in: .todo)
    model.beginCreatingItem()

    #expect(model.quickAddLane == nil)
    #expect(model.isCreatingItem)
    #expect(!model.acceptsBoardShortcuts)
  }
}
