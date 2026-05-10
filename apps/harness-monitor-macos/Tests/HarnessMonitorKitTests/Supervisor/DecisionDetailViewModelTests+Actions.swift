import XCTest

@testable import HarnessMonitorKit

extension DecisionDetailViewModelTests {
  func testAcceptInvokesResolveWithChosenAction() async {
    let action = SuggestedAction(
      id: "accept",
      title: "Accept",
      kind: .custom,
      payloadJSON: "{\"approvalID\":\"ap-1\"}"
    )
    let decision = makeDecision(suggestedActionsJSON: encodedActions([action]))
    let handler = RecordingDecisionActionHandler()
    let viewModel = DecisionDetailViewModel(decision: decision, handler: handler)

    await viewModel.invoke(action: action)

    XCTAssertEqual(handler.resolvedCalls.count, 1)
    XCTAssertEqual(handler.resolvedCalls.first?.decisionID, "d1")
    XCTAssertEqual(handler.resolvedCalls.first?.outcome.chosenActionID, "accept")
  }

  func testSnoozeActionOpensSnoozeSheet() async {
    let snooze = SuggestedAction(
      id: "snooze-1h",
      title: "Snooze 1h",
      kind: .snooze,
      payloadJSON: "{\"duration\":3600}"
    )
    let decision = makeDecision(suggestedActionsJSON: encodedActions([snooze]))
    let handler = RecordingDecisionActionHandler()
    let viewModel = DecisionDetailViewModel(decision: decision, handler: handler)

    await viewModel.invoke(action: snooze)

    XCTAssertNotNil(viewModel.snoozeRequest)
    XCTAssertEqual(viewModel.snoozeRequest?.decisionID, "d1")
    XCTAssertTrue(handler.resolvedCalls.isEmpty, "Snooze opens sheet, does not resolve directly")
  }

  func testConfirmSnoozeInvokesHandlerAndClearsSheet() async {
    let decision = makeDecision()
    let handler = RecordingDecisionActionHandler()
    let viewModel = DecisionDetailViewModel(decision: decision, handler: handler)
    viewModel.snoozeRequest = DecisionDetailViewModel.SnoozeRequest(decisionID: "d1")

    await viewModel.confirmSnooze(duration: 3600)

    XCTAssertNil(viewModel.snoozeRequest)
    XCTAssertEqual(handler.snoozeCalls.count, 1)
    XCTAssertEqual(handler.snoozeCalls.first?.decisionID, "d1")
    XCTAssertEqual(handler.snoozeCalls.first?.duration, 3600)
  }

  func testDismissActionInvokesHandler() async {
    let dismiss = SuggestedAction(
      id: "dismiss",
      title: "Dismiss",
      kind: .dismiss,
      payloadJSON: "{}"
    )
    let decision = makeDecision(suggestedActionsJSON: encodedActions([dismiss]))
    let handler = RecordingDecisionActionHandler()
    let viewModel = DecisionDetailViewModel(decision: decision, handler: handler)

    await viewModel.invoke(action: dismiss)

    XCTAssertEqual(handler.dismissCalls, ["d1"])
  }
}
