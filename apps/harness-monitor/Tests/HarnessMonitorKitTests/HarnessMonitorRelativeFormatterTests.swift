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

@MainActor
@Suite("Compact relative updated-at formatter")
struct HarnessMonitorCompactRelativeFormatterTests {
  @Test("Uses the compact task-card age units")
  func formatsCompactTaskCardAges() {
    let reference = Date(timeIntervalSince1970: 1_800_000_000)

    #expect(format(secondsAgo: 30, reference: reference) == "just now")
    #expect(format(secondsAgo: 60, reference: reference) == "1m ago")
    #expect(format(secondsAgo: 5 * 60, reference: reference) == "5m ago")
    #expect(format(secondsAgo: 60 * 60, reference: reference) == "1h ago")
    #expect(format(secondsAgo: 3 * 60 * 60, reference: reference) == "3h ago")
    #expect(format(secondsAgo: 24 * 60 * 60, reference: reference) == "1d ago")
    #expect(format(secondsAgo: 3 * 24 * 60 * 60, reference: reference) == "3d ago")
  }

  @Test("Treats future timestamps as just updated")
  func clampsFutureTimestamps() {
    let reference = Date(timeIntervalSince1970: 1_800_000_000)

    #expect(format(secondsAgo: -60, reference: reference) == "just now")
  }

  @Test("Omits missing or invalid timestamps")
  func omitsInvalidTimestamps() {
    #expect(formatCompactRelativeUpdatedAt(nil).isEmpty)
    #expect(formatCompactRelativeUpdatedAt("not-a-date").isEmpty)
  }

  private func format(secondsAgo: TimeInterval, reference: Date) -> String {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime]
    let value = formatter.string(from: reference.addingTimeInterval(-secondsAgo))
    return formatCompactRelativeUpdatedAt(value, reference: reference)
  }
}
