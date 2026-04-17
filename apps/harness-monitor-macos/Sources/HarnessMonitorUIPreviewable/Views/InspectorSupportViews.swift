import HarnessMonitorKit
import SwiftUI

public struct InspectorFact: Identifiable {
  public let title: String
  public let value: String
  public var id: String { title }
  public init(title: String, value: String) {
    self.title = title
    self.value = value
  }
}

public struct InspectorFactGrid: View {
  public let facts: [InspectorFact]

  public init(facts: [InspectorFact]) {
    self.facts = facts
  }

  public var body: some View {
    HarnessMonitorAdaptiveGridLayout(
      minimumColumnWidth: 132,
      maximumColumns: 2,
      spacing: HarnessMonitorTheme.itemSpacing
    ) {
      ForEach(facts) { fact in
        VStack(alignment: .leading, spacing: 4) {
          Text(fact.title.uppercased())
            .scaledFont(.caption2.weight(.bold))
            .tracking(HarnessMonitorTheme.uppercaseTracking)
            .foregroundStyle(HarnessMonitorTheme.secondaryInk)
          Text(fact.value)
            .scaledFont(.system(.body, design: .rounded, weight: .semibold))
            .lineLimit(2)
        }
        .frame(maxWidth: .infinity, minHeight: 52, alignment: .leading)
        .harnessCellPadding()
      }
    }
  }
}

public struct InspectorSection<Content: View>: View {
  public let title: String
  @ViewBuilder public let content: Content

  public init(title: String, @ViewBuilder content: () -> Content) {
    self.title = title
    self.content = content()
  }

  public var body: some View {
    VStack(alignment: .leading, spacing: HarnessMonitorTheme.itemSpacing) {
      Text(title)
        .scaledFont(.caption.bold())
        .foregroundStyle(HarnessMonitorTheme.secondaryInk)
      content
    }
  }
}

public struct InspectorBadgeColumn: View {
  public let values: [String]

  public init(values: [String]) {
    self.values = values
  }

  public var body: some View {
    VStack(alignment: .leading, spacing: HarnessMonitorTheme.itemSpacing) {
      ForEach(Array(values.enumerated()), id: \.offset) { _, value in
        Text(value)
          .scaledFont(.caption.weight(.semibold))
          .harnessPillPadding()
          .harnessContentPill()
      }
    }
  }
}

extension JSONValue {
  private static let prettyEncoder: JSONEncoder = {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    return encoder
  }()

  func prettyPrintedJSONString() -> String {
    guard let data = try? Self.prettyEncoder.encode(self),
      let string = String(data: data, encoding: .utf8)
    else {
      return "null"
    }
    return string
  }
}
