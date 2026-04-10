import Foundation
import Testing

@testable import HarnessMonitorKit

@Suite("SessionSignalRecord effective status")
struct SessionSignalRecordEffectiveStatusTests {
  private static let farFuture = "2099-12-31T23:59:59Z"
  private static let farPast = "2000-01-01T00:00:00Z"

  private func makeRecord(
    status: SessionSignalStatus,
    expiresAt: String,
    metadata: JSONValue = .object([:])
  ) -> SessionSignalRecord {
    SessionSignalRecord(
      runtime: "claude",
      agentId: "claude-leader",
      sessionId: "sess-1",
      status: status,
      signal: Signal(
        signalId: "sig-1",
        version: 1,
        createdAt: "2020-01-01T00:00:00Z",
        expiresAt: expiresAt,
        sourceAgent: "claude",
        command: "inject_context",
        priority: .normal,
        payload: SignalPayload(
          message: "test",
          actionHint: nil,
          relatedFiles: [],
          metadata: metadata
        ),
        delivery: DeliveryConfig(
          maxRetries: 3,
          retryCount: 0,
          idempotencyKey: nil
        )
      ),
      acknowledgment: nil
    )
  }

  @Test("Pending signal past expiry flips to expired")
  func pendingPastExpiryFlipsToExpired() {
    let record = makeRecord(status: .pending, expiresAt: Self.farPast)
    #expect(record.effectiveStatus == .expired)
  }

  @Test("Pending signal with future expiry stays pending")
  func pendingFutureExpiryStaysPending() {
    let record = makeRecord(status: .pending, expiresAt: Self.farFuture)
    #expect(record.effectiveStatus == .pending)
  }

  @Test("Acknowledged signal never transitions to expired")
  func acknowledgedPastExpiryStaysAcknowledged() {
    let record = makeRecord(status: .acknowledged, expiresAt: Self.farPast)
    #expect(record.effectiveStatus == .acknowledged)
  }

  @Test("Rejected signal never transitions to expired")
  func rejectedPastExpiryStaysRejected() {
    let record = makeRecord(status: .rejected, expiresAt: Self.farPast)
    #expect(record.effectiveStatus == .rejected)
  }

  @Test("Deferred signal never transitions to expired")
  func deferredPastExpiryStaysDeferred() {
    let record = makeRecord(status: .deferred, expiresAt: Self.farPast)
    #expect(record.effectiveStatus == .deferred)
  }

  @Test("Already expired status stays expired")
  func alreadyExpiredStaysExpired() {
    let record = makeRecord(status: .expired, expiresAt: Self.farFuture)
    #expect(record.effectiveStatus == .expired)
  }

  @Test("Malformed expiry timestamp stays pending")
  func malformedExpiryStaysPending() {
    let record = makeRecord(status: .pending, expiresAt: "not-a-timestamp")
    #expect(record.effectiveStatus == .pending)
  }

  @Test("Injected now allows deterministic comparison")
  func injectedNowControlsComparison() {
    let record = makeRecord(status: .pending, expiresAt: "2026-06-01T12:00:00Z")
    let beforeExpiry = Date(timeIntervalSince1970: 1_770_000_000)
    let afterExpiry = Date(timeIntervalSince1970: 1_800_000_000)
    #expect(record.effectiveStatus(now: beforeExpiry) == .pending)
    #expect(record.effectiveStatus(now: afterExpiry) == .expired)
  }

  @Test("Timestamp with fractional seconds parses correctly")
  func fractionalSecondsExpiryParses() {
    let record = makeRecord(status: .pending, expiresAt: "2000-01-01T00:00:00.123Z")
    #expect(record.effectiveStatus == .expired)
  }

  @Test("expiresAtDate exposes parsed date")
  func expiresAtDateParses() {
    let record = makeRecord(status: .pending, expiresAt: "2026-06-01T12:00:00Z")
    #expect(record.expiresAtDate != nil)
  }

  @Test("expiresAtDate returns nil on malformed input")
  func expiresAtDateNilOnMalformed() {
    let record = makeRecord(status: .pending, expiresAt: "not-a-timestamp")
    #expect(record.expiresAtDate == nil)
  }
}

@Suite("JSONValue structural emptiness")
struct JSONValueStructurallyEmptyTests {
  @Test("Null is structurally empty")
  func nullIsEmpty() {
    #expect(JSONValue.null.isStructurallyEmpty)
  }

  @Test("Empty object is structurally empty")
  func emptyObjectIsEmpty() {
    #expect(JSONValue.object([:]).isStructurallyEmpty)
  }

  @Test("Empty array is structurally empty")
  func emptyArrayIsEmpty() {
    #expect(JSONValue.array([]).isStructurallyEmpty)
  }

  @Test("Object with entries is not empty")
  func nonEmptyObjectIsNotEmpty() {
    #expect(!JSONValue.object(["key": .string("value")]).isStructurallyEmpty)
  }

  @Test("Array with entries is not empty")
  func nonEmptyArrayIsNotEmpty() {
    #expect(!JSONValue.array([.number(1)]).isStructurallyEmpty)
  }

  @Test("Scalar values are not empty")
  func scalarsAreNotEmpty() {
    #expect(!JSONValue.bool(false).isStructurallyEmpty)
    #expect(!JSONValue.number(0).isStructurallyEmpty)
    #expect(!JSONValue.string("").isStructurallyEmpty)
  }

  @Test("SignalPayload defaults missing metadata to empty object")
  func decodingMissingMetadataDefaultsEmpty() throws {
    let json = """
      {
        "message": "hello",
        "relatedFiles": []
      }
      """
    let payload = try JSONDecoder().decode(SignalPayload.self, from: Data(json.utf8))
    #expect(payload.metadata.isStructurallyEmpty)
  }

  @Test("SignalPayload with explicit empty object metadata is empty")
  func decodingExplicitEmptyObjectIsEmpty() throws {
    let json = """
      {
        "message": "hello",
        "relatedFiles": [],
        "metadata": {}
      }
      """
    let payload = try JSONDecoder().decode(SignalPayload.self, from: Data(json.utf8))
    #expect(payload.metadata.isStructurallyEmpty)
  }

  @Test("SignalPayload with populated metadata is not empty")
  func decodingPopulatedMetadataIsNotEmpty() throws {
    let json = """
      {
        "message": "hello",
        "relatedFiles": [],
        "metadata": {"key": "value"}
      }
      """
    let payload = try JSONDecoder().decode(SignalPayload.self, from: Data(json.utf8))
    #expect(!payload.metadata.isStructurallyEmpty)
  }
}
