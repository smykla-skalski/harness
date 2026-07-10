import Testing

@testable import HarnessMonitorKit

extension TaskBoardAPIClientTests {
  func assertReviewsWebSocketResolvePayload(_ call: RPCProbe.Call) {
    let expectedReference = JSONValue.object([
      "repository": .string("example/harness"),
      "number": .number(42),
    ])
    let expectedReferences = JSONValue.array([expectedReference])
    #expect(resolveObjectValue(call.params, key: "references") == expectedReferences)
    #expect(resolveObjectValue(call.params, key: "backport_detection_enabled") == .bool(true))
    let expectedPatterns = JSONValue.array(
      ReviewsQueryRequest.defaultBackportPatterns.map(JSONValue.string)
    )
    #expect(resolveObjectValue(call.params, key: "backport_patterns") == expectedPatterns)
  }

  func assertReviewsResolveResult(_ response: ReviewsPullRequestResolveResponse) {
    #expect(response.items.first?.pullRequestID == "pr-42")
    #expect(
      response.missingReferences
        == [ReviewsPullRequestReference(repository: "example/missing", number: 404)]
    )
  }

  private func resolveObjectValue(_ value: JSONValue?, key: String) -> JSONValue? {
    guard case .object(let object)? = value else {
      return nil
    }
    return object[key]
  }
}
