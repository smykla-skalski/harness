import Foundation
import Testing

@testable import HarnessMonitorKit

/// Guards the JSON wire shape of the reviews-policy models against the Rust
/// daemon. Requests must encode the merge method under `method`, never
/// `merge_method`. Responses must decode when the daemon omits empty
/// collections: `ReviewsPolicyPreviewResponse.steps`/`warnings`,
/// `ReviewsPolicyRunResponse.steps`, and `ReviewsPolicyStatusResponse.recentRuns`
/// all carry `#[serde(skip_serializing_if = "Vec::is_empty")]` on the daemon, so
/// those keys are absent for an ineligible PR with no applicable actions.
struct ReviewsPolicyRequestWireKeyTests {
  private func snakeCaseEncoder() -> JSONEncoder {
    let encoder = JSONEncoder()
    encoder.keyEncodingStrategy = .convertToSnakeCase
    return encoder
  }

  private func snakeCaseDecoder() -> JSONDecoder {
    let decoder = JSONDecoder()
    decoder.keyDecodingStrategy = .convertFromSnakeCase
    return decoder
  }

  private func encodedKeys(_ value: some Encodable) throws -> Set<String> {
    let data = try snakeCaseEncoder().encode(value)
    let object = try JSONSerialization.jsonObject(with: data)
    guard let dictionary = object as? [String: Any] else {
      return []
    }
    return Set(dictionary.keys)
  }

  private func policyTarget() -> ReviewTarget {
    ReviewTarget(
      pullRequestID: "pr-7",
      repositoryID: "repo-1",
      repository: "example/harness",
      number: 7,
      url: "https://github.com/example/harness/pull/7",
      headSha: "abc123",
      mergeable: .mergeable,
      reviewStatus: .reviewRequired,
      checkStatus: .success,
      policyBlocked: false
    )
  }

  @Test
  func runStartRequestEncodesMergeMethodUnderMethodKey() throws {
    let request = ReviewsPolicyRunStartRequest(
      target: policyTarget(),
      method: .rebase,
      trigger: .manual
    )
    let keys = try encodedKeys(request)
    #expect(keys.contains("method"))
    #expect(!keys.contains("merge_method"))
    #expect(!keys.contains("mergeMethod"))
  }

  @Test
  func previewRequestEncodesMergeMethodUnderMethodKey() throws {
    let request = ReviewsPolicyPreviewRequest(
      target: policyTarget(),
      method: .squash
    )
    let keys = try encodedKeys(request)
    #expect(keys.contains("method"))
    #expect(!keys.contains("merge_method"))
    #expect(!keys.contains("mergeMethod"))
  }

  @Test
  func previewResponseDecodesWhenStepsAndWarningsAbsent() throws {
    let json = """
      {
        "workflow_id": "reviews_auto",
        "subject": {
          "repository": "smykla-skalski/klaudiush",
          "pull_request_number": 440
        },
        "eligible": false,
        "reason": "No policy actions are currently applicable"
      }
      """
    let response = try snakeCaseDecoder().decode(
      ReviewsPolicyPreviewResponse.self,
      from: Data(json.utf8)
    )
    #expect(response.eligible == false)
    #expect(response.steps.isEmpty)
    #expect(response.warnings.isEmpty)
  }

  @Test
  func runResponseDecodesWhenStepsAbsent() throws {
    let json = """
      {
        "workflow_id": "reviews_auto",
        "run_id": "run-1",
        "subject": {
          "repository": "smykla-skalski/klaudiush",
          "pull_request_number": 440
        },
        "trigger": "manual",
        "status": "running",
        "started_at": "2026-06-06T10:00:00Z",
        "updated_at": "2026-06-06T10:00:01Z"
      }
      """
    let response = try snakeCaseDecoder().decode(
      ReviewsPolicyRunResponse.self,
      from: Data(json.utf8)
    )
    #expect(response.steps.isEmpty)
    #expect(response.waitingOn == nil)
  }

  @Test
  func statusResponseDecodesWhenRecentRunsAbsent() throws {
    let json = """
      {
        "workflow_id": "reviews_auto",
        "subject": {
          "repository": "smykla-skalski/klaudiush",
          "pull_request_number": 440
        }
      }
      """
    let response = try snakeCaseDecoder().decode(
      ReviewsPolicyStatusResponse.self,
      from: Data(json.utf8)
    )
    #expect(response.activeRun == nil)
    #expect(response.recentRuns.isEmpty)
  }
}
