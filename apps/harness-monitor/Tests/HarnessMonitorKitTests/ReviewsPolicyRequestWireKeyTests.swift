import Foundation
import Testing

@testable import HarnessMonitorKit

/// Guards the JSON wire shape of the reviews-policy request models against the
/// Rust daemon. The daemon reads the merge method under the key `method`, so the
/// snake_case-encoded payload must carry `method`, never `merge_method`.
struct ReviewsPolicyRequestWireKeyTests {
  private func snakeCaseEncoder() -> JSONEncoder {
    let encoder = JSONEncoder()
    encoder.keyEncodingStrategy = .convertToSnakeCase
    return encoder
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
}
