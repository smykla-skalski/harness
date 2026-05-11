import Foundation

public enum SessionWindowTabTitleFormatter {
  public static func decoratedTitle(base: String, pendingDecisionCount: Int) -> String {
    guard pendingDecisionCount > 0 else { return base }
    return "\(base) (\(pendingDecisionCount))"
  }
}
