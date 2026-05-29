import Foundation
import XCTest

@testable import HarnessMonitorKit

final class ReviewTimelineEntryCodableTests: XCTestCase {
  private func roundTrip<T: Codable & Equatable>(_ value: T) throws -> T {
    let encoder = JSONEncoder()
    encoder.keyEncodingStrategy = .convertToSnakeCase
    let data = try encoder.encode(value)
    let decoder = JSONDecoder()
    decoder.keyDecodingStrategy = .convertFromSnakeCase
    return try decoder.decode(T.self, from: data)
  }

  private func decode<T: Decodable>(_ type: T.Type, from json: String) throws -> T {
    let decoder = JSONDecoder()
    decoder.keyDecodingStrategy = .convertFromSnakeCase
    return try decoder.decode(type, from: Data(json.utf8))
  }

  func testIssueCommentRoundTrips() throws {
    let entry = ReviewTimelineEntry.issueComment(
      IssueCommentPayload(
        id: "IC_001",
        createdAt: "2026-05-22T10:00:00Z",
        actor: ReviewTimelineActor(login: "alice"),
        body: "LGTM",
        reactionsTotal: 2,
        viewerDidAuthor: true,
        viewerCanEdit: true
      )
    )
    let round = try roundTrip(entry)
    XCTAssertEqual(round, entry)
    XCTAssertEqual(round.id, "IC_001")
    XCTAssertEqual(round.kind, .issueComment)
  }

  func testReviewRoundTripsWithInlineComments() throws {
    let entry = ReviewTimelineEntry.review(
      ReviewPayload(
        id: "PRR_001",
        createdAt: "2026-05-22T11:00:00Z",
        actor: ReviewTimelineActor(login: "bob"),
        state: .approved,
        body: "Looks good",
        inlineComments: [
          ReviewInlineCommentPayload(
            id: "PRRC_001",
            path: "src/foo.swift",
            position: 7,
            line: 12,
            originalLine: 12,
            diffHunk: "@@ -11,2 +11,3 @@\n context\n+added line\n context",
            body: "nit: rename",
            createdAt: "2026-05-22T11:00:05Z",
            actor: ReviewTimelineActor(login: "bob"),
            replyToId: nil,
            outdated: false
          )
        ]
      )
    )
    let round = try roundTrip(entry)
    XCTAssertEqual(round, entry)
    XCTAssertEqual(round.kind, .review)
    if case .review(let payload) = round {
      XCTAssertEqual(payload.state, .approved)
      XCTAssertEqual(payload.inlineComments.count, 1)
      XCTAssertEqual(payload.inlineComments[0].path, "src/foo.swift")
      XCTAssertEqual(payload.inlineComments[0].line, 12)
      XCTAssertFalse(payload.inlineComments[0].outdated)
    } else {
      XCTFail("expected review variant")
    }
  }

  func testReviewThreadRoundTrips() throws {
    let entry = ReviewTimelineEntry.reviewThread(
      ReviewThreadPayload(
        id: "PRRT_001",
        createdAt: "2026-05-22T12:00:00Z",
        path: "src/bar.swift",
        line: 12,
        diffSide: "RIGHT",
        diffHunk: "@@ -11,2 +11,3 @@\n context\n+thread line\n context",
        outdated: false,
        comments: [
          ReviewThreadCommentPayload(
            id: "PRTC_001",
            body: "is this still needed?",
            createdAt: "2026-05-22T12:00:10Z"
          )
        ]
      )
    )
    let round = try roundTrip(entry)
    XCTAssertEqual(round, entry)
    if case .reviewThread(let payload) = round {
      XCTAssertEqual(payload.diffSide, "RIGHT")
      XCTAssertEqual(payload.diffHunk, "@@ -11,2 +11,3 @@\n context\n+thread line\n context")
      XCTAssertFalse(payload.outdated)
    } else {
      XCTFail("expected review thread variant")
    }
  }

  func testCommitRoundTrips() throws {
    let entry = ReviewTimelineEntry.commit(
      CommitPayload(
        id: "PRC_001",
        createdAt: "2026-05-22T13:00:00Z",
        oid: "abcd1234ef5678901234567890abcdef12345678",
        abbreviatedOid: "abcd123",
        messageHeadline: "Update dep",
        committedDate: "2026-05-22T12:55:00Z",
        authorName: "Renovate Bot",
        authorLogin: "renovate"
      )
    )
    let round = try roundTrip(entry)
    XCTAssertEqual(round, entry)
  }

  func testHeadRefForcePushedRoundTrips() throws {
    let entry = ReviewTimelineEntry.headRefForcePushed(
      HeadRefForcePushedPayload(
        id: "HRFP_001",
        createdAt: "2026-05-22T14:00:00Z",
        beforeOid: "1111111111111111111111111111111111111111",
        beforeAbbreviatedOid: "1111111",
        afterOid: "2222222222222222222222222222222222222222",
        afterAbbreviatedOid: "2222222",
        refName: "renovate/foo"
      )
    )
    let round = try roundTrip(entry)
    XCTAssertEqual(round, entry)
  }

  func testSimpleActorLabeledRoundTrips() throws {
    let entry = ReviewTimelineEntry.simpleActorEvent(
      SimpleActorEventPayload(
        id: "LE_001",
        createdAt: "2026-05-22T15:00:00Z",
        actor: ReviewTimelineActor(login: "renovate-bot"),
        eventKind: .labeled,
        label: "dependencies",
        labelColor: "0366d6"
      )
    )
    let round = try roundTrip(entry)
    XCTAssertEqual(round, entry)
    XCTAssertEqual(round.kind, .labeled)
  }

  func testSimpleActorRenamedTitleCarriesOldNew() throws {
    let entry = ReviewTimelineEntry.simpleActorEvent(
      SimpleActorEventPayload(
        id: "RTE_001",
        createdAt: "2026-05-22T15:30:00Z",
        eventKind: .renamedTitle,
        oldTitle: "Old PR title",
        newTitle: "New PR title"
      )
    )
    let round = try roundTrip(entry)
    XCTAssertEqual(round, entry)
    XCTAssertEqual(round.kind, .renamedTitle)
  }

  func testUnknownRoundTrips() throws {
    let entry = ReviewTimelineEntry.unknown(
      UnknownTimelinePayload(
        id: "UNK_001",
        createdAt: "2026-05-22T16:00:00Z",
        typename: "FutureGitHubEvent",
        rawPayload: .object(["futureField": .string("future value")])
      )
    )
    let round = try roundTrip(entry)
    XCTAssertEqual(round, entry)
    XCTAssertEqual(round.kind, .unknown)
  }

  func testDecodesSnakeCaseWireFormat() throws {
    let json = """
      {
        "kind": "issue_comment",
        "id": "IC_wire",
        "created_at": "2026-05-22T17:00:00Z",
        "body": "hello",
        "is_minimized": false,
        "reactions_total": 0,
        "viewer_did_author": false,
        "viewer_can_edit": false,
        "actor": { "login": "alice", "avatar_url": null }
      }
      """
    let entry = try decode(ReviewTimelineEntry.self, from: json)
    XCTAssertEqual(entry.kind, .issueComment)
    XCTAssertEqual(entry.id, "IC_wire")
    XCTAssertEqual(entry.actor?.login, "alice")
  }

  func testResponseRoundTrips() throws {
    let response = ReviewsTimelineResponse(
      pullRequestId: "PR_response",
      entries: [
        .issueComment(
          IssueCommentPayload(
            id: "IC_001",
            createdAt: "2026-05-22T10:00:00Z",
            body: "ship it"
          )
        )
      ],
      pageInfo: ReviewTimelinePageInfo(
        startCursor: "s",
        endCursor: "e",
        hasOlder: true,
        hasNewer: false
      ),
      viewerCanComment: true,
      fetchedAt: "2026-05-22T18:00:00Z"
    )
    let round = try roundTrip(response)
    XCTAssertEqual(round, response)
  }

  func testTimelineKindCaseIterableCoversFortyFiveCases() {
    XCTAssertEqual(ReviewTimelineKind.allCases.count, 45)
  }
}
