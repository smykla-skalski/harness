import CoreGraphics

extension PolicyCanvasGraphQualityReport {
  /// One headline counter for a violation category. Shared by the deterministic
  /// dump, the lab metrics panel, and gate failure messages so all three name
  /// and count the categories identically.
  public struct Headline: Equatable, Sendable {
    public let label: String
    public let value: Int
    public let severity: PolicyCanvasQualitySeverity
    public let category: PolicyCanvasQualityCategory

    public init(
      label: String,
      value: Int,
      severity: PolicyCanvasQualitySeverity,
      category: PolicyCanvasQualityCategory
    ) {
      self.label = label
      self.value = value
      self.severity = severity
      self.category = category
    }
  }

  /// Ordered headline counts across every category, one per
  /// `PolicyCanvasQualityCategory` in declaration order.
  public var headlines: [Headline] {
    PolicyCanvasQualityCategory.allCases.map { category in
      Headline(
        label: category.label,
        value: count(for: category),
        severity: category.severity,
        category: category
      )
    }
  }

  /// Compact multi-line summary: one "label: value" line per headline.
  public func summaryText() -> String {
    headlines.map { "\($0.label): \($0.value)" }.joined(separator: "\n")
  }
}
