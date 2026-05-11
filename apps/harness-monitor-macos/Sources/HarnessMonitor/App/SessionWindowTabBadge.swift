import AppKit
import HarnessMonitorUIPreviewable

@MainActor
enum SessionWindowTabBadge {
  static let leadingSpacing = "  "
  static let badgeHeight: CGFloat = 13
  static let cornerRadius: CGFloat = 5
  static let baselineOffset: CGFloat = -2

  static func attributedTitle(base: String, pendingDecisionCount: Int) -> NSAttributedString? {
    guard pendingDecisionCount > 0 else { return nil }
    let result = NSMutableAttributedString(string: base + leadingSpacing)
    result.append(NSAttributedString(attachment: makeAttachment(count: pendingDecisionCount)))
    return result
  }

  static func makeAttachment(count: Int) -> NSTextAttachment {
    let text = "\(count)"
    let font = NSFont.systemFont(ofSize: 8, weight: .semibold)
    let knockoutAttributes: [NSAttributedString.Key: Any] = [
      .font: font,
      .foregroundColor: NSColor.black,
    ]
    let textSize = (text as NSString).size(withAttributes: knockoutAttributes)
    let horizontalPadding: CGFloat = 4
    let width = max(badgeHeight, textSize.width + horizontalPadding * 2)
    let image = NSImage(size: NSSize(width: width, height: badgeHeight), flipped: false) { rect in
      let path = NSBezierPath(roundedRect: rect, xRadius: cornerRadius, yRadius: cornerRadius)
      badgeFillColor().setFill()
      path.fill()
      guard let context = NSGraphicsContext.current?.cgContext else { return true }
      context.saveGState()
      context.setBlendMode(.destinationOut)
      let textRect = NSRect(
        x: (rect.width - textSize.width) / 2,
        y: (rect.height - textSize.height) / 2,
        width: textSize.width,
        height: textSize.height
      )
      (text as NSString).draw(in: textRect, withAttributes: knockoutAttributes)
      context.restoreGState()
      return true
    }
    image.isTemplate = false
    let attachment = NSTextAttachment()
    attachment.image = image
    attachment.bounds = NSRect(x: 0, y: baselineOffset, width: width, height: badgeHeight)
    return attachment
  }

  static func badgeFillColor() -> NSColor {
    NSColor(named: "HarnessMonitorAccent", bundle: HarnessMonitorUIAssets.bundle)
      ?? NSColor.controlAccentColor
  }
}
