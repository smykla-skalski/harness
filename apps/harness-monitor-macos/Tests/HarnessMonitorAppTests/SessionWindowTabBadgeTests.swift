import AppKit
import Testing

@testable import HarnessMonitor

@MainActor
@Suite("Session window tab badge")
struct SessionWindowTabBadgeTests {
  @Test("Returns nil when there are no pending decisions")
  func nilWhenCountIsZero() {
    let title = SessionWindowTabBadge.attributedTitle(base: "e2e", pendingDecisionCount: 0)
    #expect(title == nil)
  }

  @Test("Returns nil when count is negative")
  func nilWhenCountIsNegative() {
    let title = SessionWindowTabBadge.attributedTitle(base: "e2e", pendingDecisionCount: -1)
    #expect(title == nil)
  }

  @Test("Builds attributed title with leading base text when count is positive")
  func placesBaseTextBeforeBadge() throws {
    let title = try #require(
      SessionWindowTabBadge.attributedTitle(base: "e2e", pendingDecisionCount: 3)
    )
    let plain = title.string
    #expect(plain.hasPrefix("e2e" + SessionWindowTabBadge.leadingSpacing))
  }

  @Test("Embeds an NSTextAttachment after the leading base text")
  func badgeIsAttachmentAfterBase() throws {
    let title = try #require(
      SessionWindowTabBadge.attributedTitle(base: "session-42", pendingDecisionCount: 1)
    )
    let attachmentRange = NSRange(location: title.length - 1, length: 1)
    let attachment = title.attribute(.attachment, at: attachmentRange.location, effectiveRange: nil)
    #expect(attachment is NSTextAttachment)
  }

  @Test("Attachment renders a non-empty image for the badge")
  func attachmentImageIsNotEmpty() {
    let attachment = SessionWindowTabBadge.makeAttachment(count: 12)
    let image = attachment.image
    #expect((image?.size.width ?? 0) > 0)
    #expect(image?.size.height == SessionWindowTabBadge.badgeHeight)
  }

  @Test("Larger counts produce wider badge bounds")
  func widerBadgeForLargerCounts() {
    let one = SessionWindowTabBadge.makeAttachment(count: 1).bounds.width
    let hundred = SessionWindowTabBadge.makeAttachment(count: 100).bounds.width
    #expect(hundred > one)
  }
}
