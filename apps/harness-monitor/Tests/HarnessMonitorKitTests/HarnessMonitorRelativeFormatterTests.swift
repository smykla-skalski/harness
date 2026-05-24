import Foundation
import Testing

@testable import HarnessMonitorUIPreviewable

@MainActor
@Suite("Relative updated-at formatter")
struct HarnessMonitorRelativeFormatterTests {
  @Test("ISO timestamps render against an explicit reference date")
  func formatsRelativeAgainstReferenceDate() throws {
    let reference = Date(timeIntervalSince1970: 1_780_000_000)
    let twoMinutesAgo = reference.addingTimeInterval(-120)
    let isoFormatter = ISO8601DateFormatter()
    isoFormatter.formatOptions = [.withInternetDateTime]
    let timestamp = isoFormatter.string(from: twoMinutesAgo)

    let rendered = formatRelativeUpdatedAt(timestamp, reference: reference)

    #expect(!rendered.isEmpty)
    #expect(rendered != timestamp)
  }

  @Test("Nil and unparsable inputs fall back to the raw value or n/a")
  func returnsFallbackForUnparsableInput() {
    #expect(formatRelativeUpdatedAt(nil) == "n/a")
    #expect(formatRelativeUpdatedAt("not-a-date") == "not-a-date")
  }
}
