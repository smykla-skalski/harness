import AppKit

@MainActor
enum SessionWindowTabBadge {
  static let leadingSpacing = "  "
  static let badgeHeight: CGFloat = 14
  static let baselineOffset: CGFloat = -2

  static func attributedTitle(base: String, pendingDecisionCount: Int) -> NSAttributedString? {
    guard pendingDecisionCount > 0 else { return nil }
    let result = NSMutableAttributedString(string: base + leadingSpacing)
    result.append(NSAttributedString(attachment: makeAttachment(count: pendingDecisionCount)))
    return result
  }

  static func makeAttachment(count: Int) -> NSTextAttachment {
    let text = "\(count)"
    let font = NSFont.systemFont(ofSize: 10, weight: .semibold)
    let textAttributes: [NSAttributedString.Key: Any] = [
      .font: font,
      .foregroundColor: NSColor.white,
    ]
    let textSize = (text as NSString).size(withAttributes: textAttributes)
    let horizontalPadding: CGFloat = 5
    let width = max(badgeHeight, textSize.width + horizontalPadding * 2)
    let image = NSImage(size: NSSize(width: width, height: badgeHeight), flipped: false) { rect in
      let radius = rect.height / 2
      let path = NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)
      NSColor.systemRed.setFill()
      path.fill()
      let textRect = NSRect(
        x: (rect.width - textSize.width) / 2,
        y: (rect.height - textSize.height) / 2,
        width: textSize.width,
        height: textSize.height
      )
      (text as NSString).draw(in: textRect, withAttributes: textAttributes)
      return true
    }
    let attachment = NSTextAttachment()
    attachment.image = image
    attachment.bounds = NSRect(x: 0, y: baselineOffset, width: width, height: badgeHeight)
    return attachment
  }
}
