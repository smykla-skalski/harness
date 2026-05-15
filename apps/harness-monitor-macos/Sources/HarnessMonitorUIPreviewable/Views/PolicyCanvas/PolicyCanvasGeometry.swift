import CoreGraphics

extension CGPoint {
  static func - (lhs: CGPoint, rhs: CGPoint) -> CGPoint {
    CGPoint(x: lhs.x - rhs.x, y: lhs.y - rhs.y)
  }

  static func + (lhs: CGPoint, rhs: CGPoint) -> CGPoint {
    CGPoint(x: lhs.x + rhs.x, y: lhs.y + rhs.y)
  }

  static func * (lhs: CGPoint, rhs: CGFloat) -> CGPoint {
    CGPoint(x: lhs.x * rhs, y: lhs.y * rhs)
  }

  var length: CGFloat {
    hypot(x, y)
  }

  var normalized: CGPoint {
    let len = length
    guard len > 0 else {
      return .zero
    }
    return CGPoint(x: x / len, y: y / len)
  }
}
