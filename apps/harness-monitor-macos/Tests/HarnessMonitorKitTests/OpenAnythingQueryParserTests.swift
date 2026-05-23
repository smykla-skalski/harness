import Testing
@testable import HarnessMonitorKit

@Suite("OpenAnythingQueryParser")
struct OpenAnythingQueryParserTests {
  @Test("Plain query returns no scope and the literal term")
  func plainQuery() {
    let parsed = OpenAnythingQueryParser.parse("session foo")
    #expect(parsed.scope == nil)
    #expect(parsed.term == "session foo")
    #expect(parsed.prefixConsumed == false)
  }

  @Test("@sess prefix maps to .sessions and trims the prefix off the term")
  func sessionsPrefix() {
    let parsed = OpenAnythingQueryParser.parse("@sess foo bar")
    #expect(parsed.scope == .sessions)
    #expect(parsed.term == "foo bar")
    #expect(parsed.prefixConsumed)
  }

  @Test("@settings with no term leaves an empty term")
  func emptyTerm() {
    let parsed = OpenAnythingQueryParser.parse("@settings")
    #expect(parsed.scope == .settings)
    #expect(parsed.term == "")
    #expect(parsed.prefixConsumed)
  }

  @Test("Unknown token does not consume the prefix")
  func unknownToken() {
    let parsed = OpenAnythingQueryParser.parse("@foo bar")
    #expect(parsed.scope == nil)
    #expect(parsed.term == "@foo bar")
    #expect(parsed.prefixConsumed == false)
  }

  @Test("@pr maps to .reviews")
  func reviewsPrefix() {
    let parsed = OpenAnythingQueryParser.parse("@pr renovate")
    #expect(parsed.scope == .reviews)
    #expect(parsed.term == "renovate")
  }

  @Test("Whitespace around the prefix is tolerated")
  func surroundingWhitespace() {
    let parsed = OpenAnythingQueryParser.parse("   @task   triage   ")
    #expect(parsed.scope == .taskBoard)
    #expect(parsed.term == "triage")
  }

  @Test("Token matching is case-insensitive")
  func caseInsensitive() {
    let parsed = OpenAnythingQueryParser.parse("@SESSIONS Foo")
    #expect(parsed.scope == .sessions)
    #expect(parsed.term == "Foo")
  }
}
