import Foundation
import Testing

@testable import HarnessMonitorKit

/// Wire-contract regression for the reviews enums generated from
/// src/reviews/enums.rs. They are adopted directly (the generated enums replace
/// the hand HarnessMonitorReviewsEnums file), so this pins the snake_case wire
/// mapping, the open-enum unknown fallback, that an explicit Rust `Unknown`
/// variant collapses into the catch-all rather than a dedicated case, and that
/// the lone closed enum (ReviewAuthorAssociation) rejects unrecognized values
/// like its closed Rust source.
@Suite("Reviews enums decoding")
struct ReviewsEnumsDecodingTests {
  private let decoder = JSONDecoder()

  @Test("decodes snake_case wire values to the matching case")
  func decodesKnownValues() throws {
    #expect(try decoder.decode(ReviewPullRequestState.self, from: Data("\"merged\"".utf8)) == .merged)
    #expect(
      try decoder.decode(ReviewReviewStatus.self, from: Data("\"review_required\"".utf8))
        == .reviewRequired
    )
    #expect(
      try decoder.decode(ReviewCheckConclusion.self, from: Data("\"startup_failure\"".utf8))
        == .startupFailure
    )
    #expect(
      try decoder.decode(ReviewActionKind.self, from: Data("\"rerun_checks\"".utf8)) == .rerunChecks
    )
  }

  @Test("decodes an unrecognized value to the unknown fallback")
  func decodesUnknownFallback() throws {
    #expect(
      try decoder.decode(ReviewPullRequestState.self, from: Data("\"draft\"".utf8)) == .unknown("draft")
    )
    // The Rust `Unknown` variant has no dedicated Swift case; its wire value
    // falls into the open-enum catch-all like any other unrecognized value.
    #expect(
      try decoder.decode(ReviewMergeableState.self, from: Data("\"unknown\"".utf8))
        == .unknown("unknown")
    )
  }

  @Test("round-trips a known case through encode")
  func roundTripsKnownCase() throws {
    let data = try JSONEncoder().encode(ReviewCheckRunStatus.inProgress)
    #expect(String(decoding: data, as: UTF8.self) == "\"in_progress\"")
  }

  @Test("decodes the closed author association and rejects unknown values")
  func decodesAuthorAssociation() throws {
    #expect(
      try decoder.decode(ReviewAuthorAssociation.self, from: Data("\"first_time_contributor\"".utf8))
        == .firstTimeContributor
    )
    #expect(try decoder.decode(ReviewAuthorAssociation.self, from: Data("\"other\"".utf8)) == .other)
    #expect(
      try decoder.decode(ReviewAuthorAssociation.self, from: Data("\"none\"".utf8))
        == ReviewAuthorAssociation.none
    )
    // Closed enum: an unrecognized value fails to decode (no open fallback),
    // mirroring the closed Rust enum's strict deserialization.
    #expect(throws: (any Error).self) {
      try decoder.decode(ReviewAuthorAssociation.self, from: Data("\"sponsor\"".utf8))
    }
  }
}
