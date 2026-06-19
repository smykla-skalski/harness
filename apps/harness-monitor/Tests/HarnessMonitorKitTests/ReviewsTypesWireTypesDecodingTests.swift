import Foundation
import Testing

@testable import HarnessMonitorKit

/// Wire-contract regression for the reviews types-core generated from
/// src/reviews/types.rs (query / item / check / action / policy surface). This
/// pins the distinctive shapes the generator handles for this cluster: a
/// `#[serde(flatten)]` flag struct inlined into its parent (ReviewTarget flattens
/// ReviewTargetFlags), the custom default fns from logic.rs, the adopted open
/// enums referenced bare, and a BTreeMap field decoded as a Swift dictionary.
/// Mapping these wire types to the rich hand models is a follow-up.
@Suite("Reviews types wire types decoding")
struct ReviewsTypesWireTypesDecodingTests {
  private let decoder = PolicyWireCoding.decoder

  @Test("decodes a review target with its flattened flag fields and defaults")
  func decodesReviewTargetWithFlattenedFlags() throws {
    // is_draft / policy_blocked are flattened ReviewTargetFlags fields and arrive
    // at the top level next to the target fields; viewer_can_update is omitted so
    // it takes its logic.rs default (true).
    let json = #"""
      {"pull_request_id":"pr-1","repository_id":"r-1","repository":"o/r","number":42,
      "url":"https://example.com/pr/42","state":"open","head_sha":"abc123",
      "mergeable":"mergeable","review_status":"approved","check_status":"success",
      "is_draft":false,"policy_blocked":true,"required_failed_check_names":[],
      "check_suite_ids":[]}
      """#
    let target = try decoder.decode(ReviewTargetWire.self, from: Data(json.utf8))

    #expect(target.pullRequestId == "pr-1")
    #expect(target.number == 42)
    #expect(target.state == .open)
    #expect(target.mergeable == .mergeable)
    #expect(target.isDraft == false)
    #expect(target.policyBlocked == true)
    #expect(target.viewerCanUpdate == true)
  }

  @Test("decodes review item target branch metadata")
  func decodesReviewItemTargetBranchMetadata() throws {
    let json = #"""
      {"pull_request_id":"pr-1","repository_id":"r-1","repository":"o/r","number":42,
      "title":"Ship release branch","url":"https://example.com/pr/42",
      "base_ref_name":"release/3.4","default_branch_name":"main",
      "author_login":"octocat","author_association":"none","state":"open",
      "mergeable":"mergeable","review_status":"review_required","check_status":"pending",
      "head_sha":"abc123","additions":2,"deletions":1,
      "created_at":"2026-06-19T10:00:00Z","updated_at":"2026-06-19T11:00:00Z"}
      """#
    let item = try decoder.decode(ReviewItemWire.self, from: Data(json.utf8))

    #expect(item.baseRefName == "release/3.4")
    #expect(item.defaultBranchName == "main")
  }

  @Test("decodes policy run metrics with a dictionary field")
  func decodesPolicyRunMetricsDict() throws {
    // The counters are required (the struct derives Default for construction but
    // the fields carry no serde default); by_trigger is the dictionary field.
    let json = #"""
      {"total":4,"running":1,"waiting":0,"completed":2,"failed":1,"cancelled":0,
      "by_trigger":{"manual":3,"scheduled":1}}
      """#
    let metrics = try decoder.decode(ReviewsPolicyRunMetricsWire.self, from: Data(json.utf8))

    #expect(metrics.total == 4)
    #expect(metrics.running == 1)
    #expect(metrics.byTrigger["manual"] == 3)
    #expect(metrics.byTrigger["scheduled"] == 1)
  }

  @Test("defaults omitted policy run metrics to a zeroed struct")
  func decodesHistoryResponseDefaultingMetrics() throws {
    // metrics carries #[serde(default)] over the Default-deriving
    // ReviewsPolicyRunMetrics struct; omitting it (along with the defaulted runs
    // and timeline) falls back to the zero struct rather than failing the decode.
    let json = #"""
      {"workflow_id":"reviews_auto","subject":{"repository":"o/r","pull_request_number":42}}
      """#
    let response = try decoder.decode(ReviewsPolicyHistoryResponseWire.self, from: Data(json.utf8))

    #expect(response.metrics == ReviewsPolicyRunMetricsWire())
    #expect(response.metrics.total == 0)
    #expect(response.runs.isEmpty)
    #expect(response.timeline.isEmpty)
  }
}
