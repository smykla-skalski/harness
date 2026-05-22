import Foundation
import Testing

@testable import HarnessMonitorKit

struct SupervisorAuditRedactorTests {
  @Test("token key value is masked")
  func tokenKeyValueIsMasked() throws {
    let raw = #"{"token":"abc123"}"#
    let redacted = redactSupervisorPayloadJSON(raw)
    let object = try jsonObject(from: redacted)
    #expect(object["token"] as? String == "[redacted]")
  }

  @Test("secret key value is masked")
  func secretKeyValueIsMasked() throws {
    let raw = #"{"secret":"shh"}"#
    let redacted = redactSupervisorPayloadJSON(raw)
    let object = try jsonObject(from: redacted)
    #expect(object["secret"] as? String == "[redacted]")
  }

  @Test("password key value is masked")
  func passwordKeyValueIsMasked() throws {
    let raw = #"{"password":"hunter2"}"#
    let redacted = redactSupervisorPayloadJSON(raw)
    let object = try jsonObject(from: redacted)
    #expect(object["password"] as? String == "[redacted]")
  }

  @Test("api_key value is masked")
  func apiKeyValueIsMasked() throws {
    let raw = #"{"api_key":"sk_test_xyz"}"#
    let redacted = redactSupervisorPayloadJSON(raw)
    let object = try jsonObject(from: redacted)
    #expect(object["api_key"] as? String == "[redacted]")
  }

  @Test("Authorization header is masked case-insensitively")
  func authorizationCaseInsensitive() throws {
    let raw = #"{"Authorization":"Bearer xyz"}"#
    let redacted = redactSupervisorPayloadJSON(raw)
    let object = try jsonObject(from: redacted)
    #expect(object["Authorization"] as? String == "[redacted]")
  }

  @Test("auth key value is masked")
  func authKeyValueIsMasked() throws {
    let raw = #"{"auth":"basic dXNlcg=="}"#
    let redacted = redactSupervisorPayloadJSON(raw)
    let object = try jsonObject(from: redacted)
    #expect(object["auth"] as? String == "[redacted]")
  }

  @Test("non-sensitive keys pass through unchanged")
  func nonSensitiveKeysPassthrough() throws {
    let raw = #"{"ruleID":"stuck_agent","count":3}"#
    let redacted = redactSupervisorPayloadJSON(raw)
    let object = try jsonObject(from: redacted)
    #expect(object["ruleID"] as? String == "stuck_agent")
    #expect((object["count"] as? NSNumber)?.intValue == 3)
  }

  @Test("nested objects are walked recursively")
  func nestedObjectsAreWalked() throws {
    let raw = #"{"outer":{"token":"abc","name":"alice"}}"#
    let redacted = redactSupervisorPayloadJSON(raw)
    let object = try jsonObject(from: redacted)
    let nested = try #require(object["outer"] as? [String: Any])
    #expect(nested["token"] as? String == "[redacted]")
    #expect(nested["name"] as? String == "alice")
  }

  @Test("arrays of objects are walked")
  func arraysAreWalked() throws {
    let raw = #"{"items":[{"token":"a"},{"name":"b"}]}"#
    let redacted = redactSupervisorPayloadJSON(raw)
    let object = try jsonObject(from: redacted)
    let array = try #require(object["items"] as? [[String: Any]])
    #expect(array[0]["token"] as? String == "[redacted]")
    #expect(array[1]["name"] as? String == "b")
  }

  @Test("non-string scalars are untouched")
  func nonStringScalarsUntouched() throws {
    let raw = #"{"count":42,"ratio":0.5,"flag":true,"missing":null}"#
    let redacted = redactSupervisorPayloadJSON(raw)
    let object = try jsonObject(from: redacted)
    #expect((object["count"] as? NSNumber)?.intValue == 42)
    #expect((object["ratio"] as? NSNumber)?.doubleValue == 0.5)
    #expect((object["flag"] as? NSNumber)?.boolValue == true)
    #expect(object["missing"] is NSNull)
  }

  @Test("malformed JSON returns input unchanged")
  func malformedJSONIsPassthrough() {
    let raw = "not a json document"
    #expect(redactSupervisorPayloadJSON(raw) == raw)
  }

  @Test("Slack xox token prefix is masked even when key is benign")
  func slackPrefixDetected() throws {
    let raw = #"{"value":"xoxb-1234567890-abcdef"}"#
    let redacted = redactSupervisorPayloadJSON(raw)
    let object = try jsonObject(from: redacted)
    #expect(object["value"] as? String == "[redacted]")
  }

  @Test("GitHub ghp_ token prefix is masked")
  func githubPrefixDetected() throws {
    let raw = #"{"value":"ghp_1234567890abcdef"}"#
    let redacted = redactSupervisorPayloadJSON(raw)
    let object = try jsonObject(from: redacted)
    #expect(object["value"] as? String == "[redacted]")
  }

  @Test("GitHub ghs_ token prefix is masked")
  func githubServerPrefixDetected() throws {
    let raw = #"{"value":"ghs_serverabc"}"#
    let redacted = redactSupervisorPayloadJSON(raw)
    let object = try jsonObject(from: redacted)
    #expect(object["value"] as? String == "[redacted]")
  }

  @Test("GitHub gho_ token prefix is masked")
  func githubUserPrefixDetected() throws {
    let raw = #"{"value":"gho_userabc"}"#
    let redacted = redactSupervisorPayloadJSON(raw)
    let object = try jsonObject(from: redacted)
    #expect(object["value"] as? String == "[redacted]")
  }

  @Test("GitHub ghr_ token prefix is masked")
  func githubRefreshPrefixDetected() throws {
    let raw = #"{"value":"ghr_refreshabc"}"#
    let redacted = redactSupervisorPayloadJSON(raw)
    let object = try jsonObject(from: redacted)
    #expect(object["value"] as? String == "[redacted]")
  }

  @Test("OpenAI sk- token prefix is masked")
  func openAIPrefixDetected() throws {
    let raw = #"{"value":"sk-abcdef123"}"#
    let redacted = redactSupervisorPayloadJSON(raw)
    let object = try jsonObject(from: redacted)
    #expect(object["value"] as? String == "[redacted]")
  }

  @Test("Anthropic pat_ token prefix is masked")
  func anthropicPrefixDetected() throws {
    let raw = #"{"value":"pat_anthropicabc"}"#
    let redacted = redactSupervisorPayloadJSON(raw)
    let object = try jsonObject(from: redacted)
    #expect(object["value"] as? String == "[redacted]")
  }

  @Test("benign string values without provider prefixes are unchanged")
  func benignStringsPassthrough() throws {
    let raw = #"{"value":"hello world"}"#
    let redacted = redactSupervisorPayloadJSON(raw)
    let object = try jsonObject(from: redacted)
    #expect(object["value"] as? String == "hello world")
  }

  @Test("error message redactor uses the shared key set")
  func errorRedactorUsesSharedConstants() {
    let redacted = redactSupervisorErrorMessage("connect failed token=abc auth=xyz")
    #expect(!redacted.contains("abc"))
    #expect(!redacted.contains("xyz"))
    #expect(redacted.contains("[redacted]"))
  }

  // MARK: - helpers

  private func jsonObject(from raw: String) throws -> [String: Any] {
    let data = try #require(raw.data(using: .utf8))
    let parsed = try JSONSerialization.jsonObject(with: data)
    return try #require(parsed as? [String: Any])
  }
}
