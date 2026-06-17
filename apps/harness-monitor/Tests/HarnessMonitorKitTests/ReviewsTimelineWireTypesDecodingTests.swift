import Foundation
import Testing

@testable import HarnessMonitorKit

/// Wire-contract regression for the reviews timeline types generated from
/// src/reviews/timeline/{types,mod}.rs. ReviewTimelineEntryWire is an internally
/// tagged enum (tag "kind") whose newtype variants re-decode the inner entry
/// from the same container; this pins that decode, the Box-unwrapped
/// SimpleActorEvent variant, the chrono DateTime->String fields, and the
/// UnknownEntry raw_payload that defaults to JSONValue.null when the daemon
/// omits it. Mapping these wire types to the rich hand models is a follow-up.
@Suite("Reviews timeline wire types decoding")
struct ReviewsTimelineWireTypesDecodingTests {
  private let decoder = PolicyWireCoding.decoder

  @Test("decodes an issue comment timeline entry through the kind tag")
  func decodesIssueCommentEntry() throws {
    let json = #"""
    {"kind":"issue_comment","id":"ic-1","created_at":"2026-06-15T00:00:00Z","actor":{"login":"alice"},"body":"hello","is_minimized":false,"reactions_total":3,"viewer_did_author":true,"viewer_can_edit":true}
    """#
    let entry = try decoder.decode(ReviewTimelineEntryWire.self, from: Data(json.utf8))

    guard case .issueComment(let comment) = entry else {
      Issue.record("expected issueComment, got \(entry)")
      return
    }
    #expect(comment.id == "ic-1")
    #expect(comment.body == "hello")
    #expect(comment.actor?.login == "alice")
    #expect(comment.reactionsTotal == 3)
  }

  @Test("decodes the boxed simple actor event variant")
  func decodesSimpleActorEventEntry() throws {
    let json = #"""
    {"kind":"simple_actor_event","id":"se-1","created_at":"2026-06-15T00:00:00Z","event_kind":"head_ref_deleted"}
    """#
    let entry = try decoder.decode(ReviewTimelineEntryWire.self, from: Data(json.utf8))

    guard case .simpleActorEvent(let event) = entry else {
      Issue.record("expected simpleActorEvent, got \(entry)")
      return
    }
    #expect(event.id == "se-1")
    #expect(event.eventKind == .headRefDeleted)
  }

  @Test("defaults an absent raw payload to JSONValue.null")
  func decodesUnknownEntryWithDefaultPayload() throws {
    let json = #"{"id":"u-1","created_at":"2026-06-15T00:00:00Z","typename":"WeirdEvent"}"#
    let entry = try decoder.decode(UnknownEntryWire.self, from: Data(json.utf8))

    #expect(entry.id == "u-1")
    #expect(entry.actor == nil)
    #expect(entry.rawPayload == JSONValue.null)
  }

  @Test("decodes the timeline enums from their snake_case wire values")
  func decodesTimelineEnums() throws {
    #expect(try decoder.decode(ReviewStateWire.self, from: Data("\"changes_requested\"".utf8)) == .changesRequested)
    #expect(try decoder.decode(TimelinePageDirectionWire.self, from: Data("\"older\"".utf8)) == .older)
    #expect(
      try decoder.decode(SimpleActorEventKindWire.self, from: Data("\"base_ref_force_pushed\"".utf8))
        == .baseRefForcePushed
    )
  }
}
